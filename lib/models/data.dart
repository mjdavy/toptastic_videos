import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart' show kIsWeb; // for web detection
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:logger/logger.dart';
import 'song.dart';

final logger = Logger();

// Base URLs for remote hosted data (aligned with toptastic-client)
const String _baseDataRoot = 'https://mjdavy.github.io/toptastic-bot';
const String _songsDbUrl = '$_baseDataRoot/songs.db';
const String _songsShaUrl = '$_baseDataRoot/songs.sha256';
const String _timestampUrl = '$_baseDataRoot/timestamp.txt';
// CSV endpoints (lighter weight for web where sqlite is limited)
const String _songsCsvUrl = '$_baseDataRoot/songs.csv';
const String _latestPlaylistCsvUrl = '$_baseDataRoot/latest_playlist.csv';

// Legacy constant kept for backward compatibility if referenced elsewhere
// (Will be removed in a later cleanup)
const String databaseURL = _songsDbUrl;

enum FetchSongsResult {
  success,
  serverNotConfigured,
  error,
}

class ServerNotConfiguredException implements Exception {
  final String message;
  ServerNotConfiguredException(this.message);
}

class FetchSongsException implements Exception {
  final String message;
  FetchSongsException(this.message);
}

/// Migration: convert old 'lastDownloaded' heuristic to new timestamp fields.
Future<void> _migrateLegacyPrefsIfNeeded(SharedPreferences prefs) async {
  if (prefs.getString('lastDownloadedTimestamp') != null) {
    return; // Already migrated
  }
  final legacy = prefs.getString('lastDownloaded');
  if (legacy != null) {
    // We can't reconstruct exact remote timestamp; trigger a refetch by clearing.
    await prefs.remove('lastDownloaded');
    // Leave new keys absent so first ensureLatestDatabase() run re-downloads.
    logger.i('Migrated legacy lastDownloaded -> triggering fresh DB fetch');
  }
}

/// Backwards compatibility helper used by UI widgets that previously reset
/// the 'lastDownloaded' heuristic. We now map this to our timestamp based
/// mechanism by simply clearing the stored timestamp so the next fetch will
/// force a re-check.
Future<void> updateLastDownloaded({bool reset = false}) async {
  final prefs = await SharedPreferences.getInstance();
  if (reset) {
    await prefs.remove('lastDownloadedTimestamp');
    await prefs.remove('lastDbSha256');
  } else {
    prefs.setString(
        'lastDownloadedTimestamp', DateTime.now().toIso8601String());
  }
}

/// Ensure the local SQLite database reflects the latest remote version.
/// Uses a lightweight remote timestamp + sha256 integrity verification.
/// Returns true if an update was applied.
Future<bool> ensureLatestDatabase() async {
  final prefs = await SharedPreferences.getInstance();
  await _migrateLegacyPrefsIfNeeded(prefs);
  final lastTs = prefs.getString('lastDownloadedTimestamp');

  http.Response tsResp;
  try {
    tsResp = await http.get(Uri.parse(_timestampUrl));
  } catch (e) {
    logger.w('Timestamp fetch failed: $e');
    return false; // Offline / network issue; keep existing DB
  }
  if (tsResp.statusCode != 200) {
    logger.w('Timestamp request bad status: ${tsResp.statusCode}');
    return false;
  }
  final remoteTs = tsResp.body.trim();
  if (remoteTs.isEmpty) {
    logger.w('Remote timestamp empty');
    return false;
  }
  if (remoteTs == lastTs) {
    // Up to date
    return false;
  }

  // Fetch expected SHA
  http.Response shaResp;
  try {
    shaResp = await http.get(Uri.parse(_songsShaUrl));
  } catch (e) {
    logger.w('SHA fetch failed: $e');
    return false;
  }
  if (shaResp.statusCode != 200) {
    logger.w('SHA request bad status: ${shaResp.statusCode}');
    return false;
  }
  final expectedSha = shaResp.body.trim().toLowerCase();
  if (expectedSha.isEmpty) {
    logger.w('Expected SHA empty');
    return false;
  }

  // Download DB
  http.Response dbResp;
  try {
    dbResp = await http.get(Uri.parse(_songsDbUrl));
  } catch (e) {
    logger.w('DB download failed: $e');
    return false;
  }
  if (dbResp.statusCode != 200) {
    logger.w('DB request bad status: ${dbResp.statusCode}');
    return false;
  }
  final bytes = dbResp.bodyBytes;
  final actualSha = sha256.convert(bytes).toString();
  if (actualSha != expectedSha) {
    logger.e('SHA mismatch. expected=$expectedSha actual=$actualSha');
    return false; // Integrity failed
  }

  // Atomic replace
  final dbDir = await getDatabasesPath();
  final finalPath = join(dbDir, 'database.db');
  final tempPath = '$finalPath.download';
  try {
    await File(tempPath).writeAsBytes(bytes, flush: true);
    if (await File(finalPath).exists()) {
      await File(finalPath).delete();
    }
    await File(tempPath).rename(finalPath);
  } catch (e) {
    logger.e('Failed to write database: $e');
    try {
      await File(tempPath).delete();
    } catch (_) {}
    return false;
  }

  prefs
    ..setString('lastDownloadedTimestamp', remoteTs)
    ..setString('lastDbSha256', expectedSha);

  logger.i('Database updated to timestamp $remoteTs (sha $expectedSha)');
  return true;
}

Future<List<Song>> fetchSongs(DateTime date) async {
  final prefs = await SharedPreferences.getInstance();
  final offlineMode = prefs.getBool('offlineMode') ?? true;
  return offlineMode ? fetchSongsOffline(date) : fetchSongsOnline(date);
}

Future<List<Song>> fetchSongsOffline(DateTime date) async {
  // On web, fall back to CSV since sqlite (sqflite) is not supported in a static web build.
  if (kIsWeb) {
    return _fetchSongsWebCsv(date);
  }
  final String formattedDate = DateFormat('yyyyMMdd').format(date);
  final dbDir = await getDatabasesPath();
  final dbPath = join(dbDir, 'database.db');
  try {
    await ensureLatestDatabase(); // Update if remote changed
    return await getSongsFromDB(dbPath, formattedDate);
  } catch (e) {
    throw FetchSongsException('Data error: $e');
  }
}

/// Web CSV bootstrap: we only have the latest playlist CSV with positions etc.
/// If user requests a different date than latest, we still return latest (until
/// historical CSV snapshots are provided). We rely on timestamp.txt for cache.
Future<List<Song>> _fetchSongsWebCsv(DateTime requestedDate) async {
  final prefs = await SharedPreferences.getInstance();
  String? cachedTs = prefs.getString('webCsvTimestamp');
  String? cachedJson = prefs.getString('webCsvSongs');

  String remoteTs = cachedTs ?? '';
  try {
    final tsResp = await http.get(Uri.parse(_timestampUrl));
    if (tsResp.statusCode == 200) {
      remoteTs = tsResp.body.trim();
    }
  } catch (e) {
    logger.w('Web CSV: timestamp fetch failed: $e');
  }

  // If we have cached data for this timestamp, use it.
  if (cachedTs != null && cachedTs == remoteTs && cachedJson != null) {
    try {
      final list = json.decode(cachedJson) as List;
      return list.map((m) => Song.fromJson(m as Map<String, dynamic>)).toList();
    } catch (e) {
      logger.w('Web CSV cache decode failed, will refetch: $e');
    }
  }

  // Fetch latest playlist CSV (smaller). If it fails, fallback to full songs CSV.
  http.Response csvResp;
  try {
    csvResp = await http.get(Uri.parse(_latestPlaylistCsvUrl));
    if (csvResp.statusCode != 200) {
      throw Exception('latest playlist csv status ${csvResp.statusCode}');
    }
  } catch (e) {
    logger.w('Latest playlist CSV fetch failed ($e), trying full songs.csv');
    try {
      csvResp = await http.get(Uri.parse(_songsCsvUrl));
      if (csvResp.statusCode != 200) {
        throw Exception('songs.csv status ${csvResp.statusCode}');
      }
    } catch (e2) {
      throw FetchSongsException('CSV fetch failed: $e2');
    }
  }

  final csvContent = csvResp.body;
  List<List<dynamic>> rows;
  try {
    rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
        .convert(csvContent);
  } catch (e) {
    throw FetchSongsException('CSV parse error: $e');
  }
  if (rows.isEmpty) return [];

  // Assume header row with names: id,artist,song_name,video_id,position,lw,peak,weeks,is_new,is_reentry
  final header = rows.first.map((h) => h.toString().trim()).toList();
  final dataRows = rows.skip(1);

  int colIndex(String name) => header.indexOf(name);
  final idxId = colIndex('id');
  final idxArtist = colIndex('artist');
  final idxSongName = colIndex('song_name');
  final idxVideo = colIndex('video_id');
  final idxPos = colIndex('position');
  final idxLw = colIndex('lw');
  final idxPeak = colIndex('peak');
  final idxWeeks = colIndex('weeks');
  final idxIsNew = colIndex('is_new');
  final idxIsRe = colIndex('is_reentry');

  bool indicesValid = [
    idxId,
    idxArtist,
    idxSongName,
    idxPos,
    idxLw,
    idxPeak,
    idxWeeks
  ].every((i) => i >= 0);
  if (!indicesValid) {
    throw FetchSongsException('CSV header missing required columns: $header');
  }

  final songs = <Song>[];
  for (final row in dataRows) {
    if (row.isEmpty) continue;
    try {
      int parseInt(dynamic v) => int.tryParse(v.toString().trim()) ?? 0;
      bool parseBool(dynamic v) {
        final s = v.toString().trim().toLowerCase();
        return s == '1' || s == 'true' || s == 'y';
      }

      final song = Song(
        id: parseInt(row[idxId]),
        artist: idxArtist >= 0 ? row[idxArtist].toString() : '',
        songName: idxSongName >= 0 ? row[idxSongName].toString() : '',
        position: idxPos >= 0 ? parseInt(row[idxPos]) : 0,
        lw: idxLw >= 0 ? parseInt(row[idxLw]) : 0,
        peak: idxPeak >= 0 ? parseInt(row[idxPeak]) : 0,
        weeks: idxWeeks >= 0 ? parseInt(row[idxWeeks]) : 0,
        isNew: idxIsNew >= 0 ? parseBool(row[idxIsNew]) : false,
        isReentry: idxIsRe >= 0 ? parseBool(row[idxIsRe]) : false,
        videoId: idxVideo >= 0 ? row[idxVideo].toString() : '',
      );
      songs.add(song);
    } catch (e) {
      logger.w('Skipping malformed row: $row ($e)');
    }
  }

  // Persist cache
  try {
    final serialized = json.encode(songs
        .map((s) => {
              'id': s.id,
              'artist': s.artist,
              'song_name': s.songName,
              'position': s.position,
              'lw': s.lw,
              'peak': s.peak,
              'weeks': s.weeks,
              'is_new': s.isNew,
              'is_reentry': s.isReentry,
              'video_id': s.videoId,
            })
        .toList());
    if (remoteTs.isNotEmpty) {
      await prefs.setString('webCsvTimestamp', remoteTs);
    }
    await prefs.setString('webCsvSongs', serialized);
  } catch (e) {
    logger.w('Failed to cache web CSV songs: $e');
  }

  return songs;
}

Future<List<Song>> getSongsFromDB(String dbPath, String formattedDate) async {
  const query = """
    SELECT 
      s.id,
      s.song_name, 
      s.artist, 
      s.video_id,
      ps.position, 
      ps.lw, 
      ps.peak, 
      ps.weeks, 
      ps.is_new, 
      ps.is_reentry
    FROM 
      playlists p 
      JOIN playlist_songs ps ON p.id = ps.playlist_id 
      JOIN songs s ON ps.song_id = s.id
    WHERE 
      p.date = ?""";

  final db = await openDatabase(dbPath, version: 1);
  final result = await db.rawQuery(query, [formattedDate]);
  return result.map((item) => Song.fromJson(item)).toList();
}

Future<List<Song>> fetchSongsOnline(DateTime date) async {
  final String formattedDate = DateFormat('yyyyMMdd').format(date);
  try {
    final serverName = await getServerUrl();
    final serverUrl = '$serverName/api/songs';
    final url = '$serverUrl/$formattedDate';
    final response = await http.get(Uri.parse(url));
    if (response.statusCode == 200) {
      final jsonResponse = json.decode(response.body) as List;
      return jsonResponse.map((item) => Song.fromJson(item)).toList();
    } else {
      throw FetchSongsException(
          'Error fetching songs. Status code: ${response.statusCode}');
    }
  } catch (e) {
    logger.i('Error fetching songs: $e');
    final prefs = await SharedPreferences.getInstance();
    prefs.setBool('offlineMode', true);
    return fetchSongsOffline(date);
  }
}

Future<String> getServerUrl() async {
  final prefs = await SharedPreferences.getInstance();
  final serverName = prefs.getString('serverName');
  final port = prefs.getString('port');
  if (serverName == null || port == null) {
    throw ServerNotConfiguredException('Server is not configured');
  }
  return 'http://$serverName:$port';
}

Future<int> updateVideos(List<Song> songs) async {
  final serverUrl = await getServerUrl();
  final updateVideosUrl = '$serverUrl/api/update_videos';
  final tracks = songs
      .where((song) => song.hasChanges)
      .map((song) => {
            'title': song.songName,
            'artist': song.artist,
            'videoId': song.videoId,
          })
      .toList();
  final requestBody = {'tracks': tracks};
  final response = await http.post(
    Uri.parse(updateVideosUrl),
    body: json.encode(requestBody),
    headers: {'Content-Type': 'application/json'},
  );
  if (response.statusCode == 200) {
    final responseData = json.decode(response.body) as Map<String, dynamic>;
    final updatedCount = responseData['updated'] as int? ?? 0;
    logger.i('Videos updated successfully. Updated $updatedCount songs.');
    return updatedCount;
  } else {
    logger.i('Failed to update videos: ${response.statusCode}');
  }
  return 0;
}
