import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

// Crea tu client_id gratis en https://devportal.jamendo.com
// Se inyecta al compilar: --dart-define=JAMENDO_CLIENT_ID=xxxx
const kClientId = String.fromEnvironment('JAMENDO_CLIENT_ID');
const kGreen = Color(0xFF1DB954);

// ---------------- Modelo y API ----------------

class Track {
  final String id, name, artist, image, audio;
  Track.fromJson(Map<String, dynamic> j)
      : id = j['id'].toString(),
        name = j['name'] ?? '',
        artist = j['artist_name'] ?? '',
        image = j['image'] ?? '',
        audio = j['audio'] ?? '';
}

class Api {
  static Future<List<Track>> tracks(
      {String? search, String? tag, int limit = 20}) async {
    final params = {
      'client_id': kClientId,
      'format': 'json',
      'limit': '$limit',
      'imagesize': '300',
      'audioformat': 'mp32',
      'order': 'popularity_week',
      if (search != null && search.isNotEmpty) 'search': search,
      if (tag != null) 'tags': tag,
    };
    final uri = Uri.https('api.jamendo.com', '/v3.0/tracks/', params);
    final res = await http.get(uri);
    if (res.statusCode != 200) throw Exception('Error ${res.statusCode}');
    final data = jsonDecode(res.body);
    return (data['results'] as List)
        .map((e) => Track.fromJson(e))
        .where((t) => t.audio.isNotEmpty)
        .toList();
  }
}

// ---------------- Reproductor ----------------

class PlayerController extends ChangeNotifier {
  final player = AudioPlayer();
  List<Track> queue = [];
  int index = -1;

  Track? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;

  PlayerController() {
    player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) next();
      notifyListeners();
    });
  }

  Future<void> playList(List<Track> list, int i) async {
    queue = list;
    index = i;
    notifyListeners();
    await _load();
  }

  Future<void> _load() async {
    final t = current;
    if (t == null) return;
    try {
      await player.setUrl(t.audio);
      player.play();
    } catch (e) {
      debugPrint('Error al reproducir: $e');
    }
    notifyListeners();
  }

  Future<void> next() async {
    if (index < queue.length - 1) {
      index++;
      await _load();
    }
  }

  Future<void> prev() async {
    if (player.position.inSeconds > 3) {
      player.seek(Duration.zero);
    } else if (index > 0) {
      index--;
      await _load();
    }
  }

  void toggle() => player.playing ? player.pause() : player.play();
}

final pc = PlayerController();

// ---------------- App ----------------

void main() => runApp(const MusicApp());

class MusicApp extends StatelessWidget {
  const MusicApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Vibra',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: Colors.black,
          colorScheme: ColorScheme.dark(primary: kGreen),
          navigationBarTheme: const NavigationBarThemeData(
            backgroundColor: Colors.black,
            indicatorColor: Colors.white12,
          ),
        ),
        home: const Shell(),
      );
}

Widget cover(String url, double size) => ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => Container(
          width: size,
          height: size,
          color: Colors.grey[850],
          child: const Icon(Icons.music_note),
        ),
      ),
    );

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: IndexedStack(
            index: tab,
            children: const [HomePage(), SearchPage()],
          ),
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(),
            NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: 'Inicio'),
                NavigationDestination(
                    icon: Icon(Icons.search), label: 'Buscar'),
              ],
            ),
          ],
        ),
      );
}

// ---------------- Inicio ----------------

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.only(top: 16, bottom: 16),
        children: const [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('¡A escuchar!',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          ),
          Section(title: 'Populares esta semana'),
          Section(title: 'Rock', tag: 'rock'),
          Section(title: 'Pop', tag: 'pop'),
          Section(title: 'Electrónica', tag: 'electronic'),
          Section(title: 'Hip hop', tag: 'hiphop'),
          Section(title: 'Jazz', tag: 'jazz'),
        ],
      );
}

class Section extends StatefulWidget {
  final String title;
  final String? tag;
  const Section({super.key, required this.title, this.tag});
  @override
  State<Section> createState() => _SectionState();
}

class _SectionState extends State<Section> {
  late final Future<List<Track>> future = Api.tracks(tag: widget.tag);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
          child: Text(widget.title,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ),
        SizedBox(
          height: 190,
          child: FutureBuilder<List<Track>>(
            future: future,
            builder: (c, s) {
              if (s.connectionState != ConnectionState.done) {
                return const Center(
                    child: CircularProgressIndicator(color: kGreen));
              }
              if (s.hasError || s.data == null) {
                return const Center(child: Text('No se pudo cargar'));
              }
              final list = s.data!;
              return ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (_, i) => GestureDetector(
                  onTap: () => pc.playList(list, i),
                  child: SizedBox(
                    width: 130,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        cover(list[i].image, 130),
                        const SizedBox(height: 6),
                        Text(list[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text(list[i].artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------- Buscar ----------------

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  Future<List<Track>>? future;

  void search(String q) {
    if (q.trim().isEmpty) return;
    setState(() => future = Api.tracks(search: q.trim(), limit: 30));
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onSubmitted: search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '¿Qué quieres escuchar?',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white12,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: future == null
                ? const Center(
                    child: Text('Busca canciones, artistas o álbumes'))
                : FutureBuilder<List<Track>>(
                    future: future,
                    builder: (c, s) {
                      if (s.connectionState != ConnectionState.done) {
                        return const Center(
                            child: CircularProgressIndicator(color: kGreen));
                      }
                      if (s.hasError || s.data == null) {
                        return const Center(child: Text('No se pudo buscar'));
                      }
                      final list = s.data!;
                      if (list.isEmpty) {
                        return const Center(child: Text('Sin resultados'));
                      }
                      return ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) => ListTile(
                          leading: cover(list[i].image, 50),
                          title: Text(list[i].name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(list[i].artist,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => pc.playList(list, i),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
}

// ---------------- Mini player ----------------

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: pc,
        builder: (context, _) {
          final t = pc.current;
          if (t == null) return const SizedBox.shrink();
          return GestureDetector(
            onTap: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              backgroundColor: const Color(0xFF181818),
              builder: (_) => const FullPlayer(),
            ),
            child: Container(
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    dense: true,
                    leading: cover(t.image, 44),
                    title: Text(t.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(t.artist,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      icon: Icon(
                          pc.player.playing ? Icons.pause : Icons.play_arrow),
                      onPressed: pc.toggle,
                    ),
                  ),
                  StreamBuilder<Duration>(
                    stream: pc.player.positionStream,
                    builder: (_, s) {
                      final total = pc.player.duration?.inMilliseconds ?? 1;
                      final pos = s.data?.inMilliseconds ?? 0;
                      return LinearProgressIndicator(
                        value: (pos / total).clamp(0.0, 1.0),
                        minHeight: 2,
                        color: Colors.white,
                        backgroundColor: Colors.white24,
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      );
}

// ---------------- Reproductor completo ----------------

class FullPlayer extends StatelessWidget {
  const FullPlayer({super.key});

  String fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: pc,
        builder: (context, _) {
          final t = pc.current;
          if (t == null) return const SizedBox.shrink();
          final side = (MediaQuery.of(context).size.width - 48).clamp(0.0, 320.0);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down, size: 32),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(height: 12),
                cover(t.image, side),
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(t.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold)),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(t.artist,
                      style: const TextStyle(color: Colors.grey)),
                ),
                const SizedBox(height: 8),
                StreamBuilder<Duration>(
                  stream: pc.player.positionStream,
                  builder: (_, s) {
                    final total = pc.player.duration ?? Duration.zero;
                    final pos = s.data ?? Duration.zero;
                    final max = total.inMilliseconds;
                    return Column(
                      children: [
                        Slider(
                          value: pos.inMilliseconds.clamp(0, max).toDouble(),
                          max: max > 0 ? max.toDouble() : 1,
                          activeColor: Colors.white,
                          onChanged: (v) =>
                              pc.player.seek(Duration(milliseconds: v.toInt())),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [Text(fmt(pos)), Text(fmt(total))],
                        ),
                      ],
                    );
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                        iconSize: 40,
                        icon: const Icon(Icons.skip_previous),
                        onPressed: pc.prev),
                    IconButton(
                      iconSize: 72,
                      color: Colors.white,
                      icon: Icon(pc.player.playing
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill),
                      onPressed: pc.toggle,
                    ),
                    IconButton(
                        iconSize: 40,
                        icon: const Icon(Icons.skip_next),
                        onPressed: pc.next),
                  ],
                ),
              ],
            ),
          );
        },
      );
}
