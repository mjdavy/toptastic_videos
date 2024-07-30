import 'package:flutter/material.dart';
import '../widgets/song_position_indicator.dart';
import '../widgets/youtube_player_screen.dart';
import '../models/song.dart';
import '../widgets/youtube_thumbnail.dart';

class SongItem extends StatefulWidget {
  final Song song;
  final bool isFavorite;

  const SongItem( {super.key, required this.song, this.isFavorite = false});

  @override
  State<SongItem> createState() => _SongItemState();
}

class _SongItemState extends State<SongItem> {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: SongPositionIndicator(widget.song),
        title: Text(
          widget.song.songName,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Text(widget.song.artist),
        trailing: widget.song.videoId.isEmpty
            ? null
            : YoutubeThumbnail(song: widget.song, isFavorite: widget.isFavorite),
        onTap: () {
          Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => YoutubePlayerScreen(song: widget.song),
          ),
        );
        },
      ),
    );
  }
}