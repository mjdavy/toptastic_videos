import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:crypto/crypto.dart';
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
  if (prefs.getString('lastDownloadedTimestamp') != null) return; // Already migrated
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
    prefs.setString('lastDownloadedTimestamp', DateTime.now().toIso8601String());
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
    try { await File(tempPath).delete(); } catch (_) {}
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
      throw FetchSongsException('Error fetching songs. Status code: ${response.statusCode}');
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
