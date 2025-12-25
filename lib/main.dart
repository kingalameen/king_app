import 'dart:io';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'kkkkkkkking gallary',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  final _storage = const FlutterSecureStorage();
  final LocalAuthentication _auth = LocalAuthentication();
  final stt.SpeechToText _speech = stt.SpeechToText();

  @override
  Widget build(BuildContext context) {
    final pages = [
      GalleryPage(onImportToVault: _importToVault),
      VaultPage(
        storage: _storage,
        auth: _auth,
        speech: _speech,
      ),
      SettingsPage(storage: _storage, auth: _auth, speech: _speech),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('kkkkkkkking gallary'),
        backgroundColor: Theme.of(context).colorScheme.primary,
      ),
      body: pages[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.photo), label: 'Gallery'),
          NavigationDestination(icon: Icon(Icons.lock), label: 'Vault'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }

  // Import an asset into the vault: copy file to app documents and try to remove original.
  Future<void> _importToVault(AssetEntity asset) async {
    try {
      final file = await asset.file;
      if (file == null) throw Exception('Could not access original file');

      final dir = await getApplicationDocumentsDirectory();
      final vaultDir = Directory('${dir.path}/vault');
      if (!await vaultDir.exists()) await vaultDir.create(recursive: true);

      final newPath = '${vaultDir.path}/${DateTime.now().millisecondsSinceEpoch}_${asset.id}${file.path.split('/').last}';
      await file.copy(newPath);

      // Attempt to delete original from gallery (requires permission and platform support).
      try {
        await PhotoManager.editor.deleteWithIds([asset.id]);
      } catch (_) {
        // ignore deletion errors; user will still have copied file inside the vault
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Imported to vault')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to import: $e')));
    }
  }
}

class GalleryPage extends StatefulWidget {
  final Future<void> Function(AssetEntity) onImportToVault;
  const GalleryPage({super.key, required this.onImportToVault});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  List<AssetEntity> assets = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) {
      setState(() => loading = false);
      return;
    }

    final albums = await PhotoManager.getAssetPathList(onlyAll: true);
    if (albums.isNotEmpty) {
      final list = await albums[0].getAssetListPaged(0, 100); // first 100
      setState(() {
        assets = list;
        loading = false;
      });
    } else {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (assets.isEmpty) return const Center(child: Text('No photos or permission denied'));

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: assets.length,
      itemBuilder: (context, index) {
        final asset = assets[index];
        return GestureDetector(
          onLongPress: () => _showImportDialog(asset),
          child: FutureBuilder<Widget>(
            future: asset.thumbnailDataWithSize(const ThumbnailSize(200, 200)).then((data) {
              if (data == null) return const SizedBox();
              return Image.memory(data, fit: BoxFit.cover);
            }),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return Container(color: Colors.grey[300]);
              return ClipRRect(borderRadius: BorderRadius.circular(8), child: snap.data ?? const SizedBox());
            },
          ),
        );
      },
    );
  }

  void _showImportDialog(AssetEntity asset) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.lock),
            title: const Text('Import to Vault'),
            onTap: () {
              Navigator.pop(context);
              widget.onImportToVault(asset);
            },
          ),
          ListTile(
            leading: const Icon(Icons.info),
            title: const Text('Details'),
            onTap: () async {
              Navigator.pop(context);
              final file = await asset.file;
              if (!mounted) return;
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Asset Info'),
                  content: Text('id: ${asset.id}\npath: ${file?.path ?? 'n/a'}'),
                ),
              );
            },
          ),
        ]),
      ),
    );
  }
}

class VaultPage extends StatefulWidget {
  final FlutterSecureStorage storage;
  final LocalAuthentication auth;
  final stt.SpeechToText speech;
  const VaultPage({super.key, required this.storage, required this.auth, required this.speech});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  bool _unlocked = false;
  List<File> _vaultFiles = [];

  @override
  void initState() {
    super.initState();
    _loadVault();
  }

  Future<void> _loadVault() async {
    final dir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory('${dir.path}/vault');
    if (await vaultDir.exists()) {
      final list = vaultDir.listSync().whereType<File>().toList();
      setState(() => _vaultFiles = list);
    }
  }

  Future<void> _authenticateWithBiometrics() async {
    try {
      final canCheck = await widget.auth.canCheckBiometrics || await widget.auth.isDeviceSupported();
      if (!canCheck) {
        _showMessage('Biometrics not available');
        return;
      }
      final didAuth = await widget.auth.authenticate(
        localizedReason: 'Unlock your vault',
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
      if (didAuth) setState(() => _unlocked = true);
    } catch (e) {
      _showMessage('Biometric error: $e');
    }
  }

  Future<void> _authenticateWithPIN() async {
    final pin = await widget.storage.read(key: 'vault_pin');
    if (pin == null) {
      _showMessage('No PIN set in Settings');
      return;
    }

    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Enter PIN'),
        content: TextField(controller: controller, obscureText: true, keyboardType: TextInputType.number),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text == pin), child: const Text('OK')),
        ],
      ),
    );

    if (ok == true) setState(() => _unlocked = true);
  }

  Future<void> _authenticateWithVoice() async {
    final phrase = await widget.storage.read(key: 'voice_phrase');
    if (phrase == null) {
      _showMessage('No voice phrase set in Settings');
      return;
    }

    final available = await widget.speech.initialize();
    if (!available) {
      _showMessage('Speech recognition unavailable');
      return;
    }

    _showMessage('Speak your passphrase now');
    final result = await widget.speech.listenOnDevice();
    // NOTE: speech_to_text has an asynchronous event model; for brevity we just start listen and wait short time.
    await Future.delayed(const Duration(seconds: 3));
    final last = widget.speech.lastRecognizedWords;
    await widget.speech.stop();

    if (last.toLowerCase().trim() == phrase.toLowerCase().trim()) {
      setState(() => _unlocked = true);
    } else {
      _showMessage('Voice did not match');
    }
  }

  void _showMessage(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    if (!_unlocked) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.lock_outline, size: 64),
          const SizedBox(height: 12),
          const Text('Vault is locked', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 18),
          ElevatedButton.icon(
            onPressed: _authenticateWithBiometrics,
            icon: const Icon(Icons.fingerprint),
            label: const Text('Unlock with Biometrics'),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: _authenticateWithPIN,
            icon: const Icon(Icons.pin),
            label: const Text('Unlock with PIN'),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: _authenticateWithVoice,
            icon: const Icon(Icons.mic),
            label: const Text('Unlock with Voice'),
          ),
        ]),
      );
    }

    return Column(
      children: [
        Expanded(
          child: _vaultFiles.isEmpty
              ? const Center(child: Text('Vault is empty'))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: _vaultFiles.length,
                  itemBuilder: (context, index) {
                    final f = _vaultFiles[index];
                    return GestureDetector(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('Preview')),
                        body: Center(child: Image.file(f)),
                      ))),
                      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(f, fit: BoxFit.cover)),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            ElevatedButton.icon(onPressed: () => setState(() => _unlocked = false), icon: const Icon(Icons.lock), label: const Text('Lock')),
            const SizedBox(width: 12),
            ElevatedButton.icon(onPressed: _loadVault, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
          ]),
        ),
      ],
    );
  }
}

class SettingsPage extends StatefulWidget {
  final FlutterSecureStorage storage;
  final LocalAuthentication auth;
  final stt.SpeechToText speech;
  const SettingsPage({super.key, required this.storage, required this.auth, required this.speech});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    final available = await widget.auth.canCheckBiometrics || await widget.auth.isDeviceSupported();
    setState(() => _biometricAvailable = available);
  }

  Future<void> _setPin() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Set PIN'),
        content: TextField(controller: controller, obscureText: true, keyboardType: TextInputType.number),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      await widget.storage.write(key: 'vault_pin', value: controller.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN saved')));
    }
  }

  Future<void> _setVoicePhrase() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Set voice phrase (short)'),
        content: TextField(controller: controller),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      await widget.storage.write(key: 'voice_phrase', value: controller.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Voice phrase saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(12), children: [
      ListTile(
        leading: const Icon(Icons.fingerprint),
        title: const Text('Biometric available'),
        subtitle: Text(_biometricAvailable ? 'Yes' : 'No'),
      ),
      ListTile(
        leading: const Icon(Icons.pin),
        title: const Text('Set/Change PIN'),
        onTap: _setPin,
      ),
      ListTile(
        leading: const Icon(Icons.mic),
        title: const Text('Set voice phrase'),
        onTap: _setVoicePhrase,
      ),
      const SizedBox(height: 16),
      const Text('Notes:', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      const Text('- Imported images are copied to the app vault folder (private app storage).\n- App attempts to delete the original image but this may fail depending on platform permissions.\n- You must run `flutter pub get` after changing pubspec and grant gallery and microphone permissions on device.'),
    ]);
  }
}
