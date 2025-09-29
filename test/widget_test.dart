// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:toptastic_videos/main.dart';
import 'package:toptastic_videos/models/favorites_songs_model.dart';

void main() {
  testWidgets('App boots with TopTastic home screen', (tester) async {
    final favorites = FavoriteSongsModel();
    // Don't await loadFavoriteIds here; the model loads asynchronously and notifies.
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: favorites,
        child: const MyApp(),
      ),
    );

    // Initial frame.
    await tester.pump();

    // Verify title text appears.
    expect(find.textContaining('TopTastic'), findsOneWidget);

    // Verify playlist icon button (play arrow) exists (may be disabled if no songs yet).
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });
}
