import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final supabase = Supabase.instance.client;
  final _usernameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final ImagePicker _picker = ImagePicker();

  bool _loading = true;
  bool _saving = false;
  bool _uploadingAvatar = false;
  String? _email;
  String? _avatarUrl;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final userId = supabase.auth.currentUser!.id;
    try {
      final data = await supabase.from('profiles').select().eq('id', userId).single();
      setState(() {
        _usernameController.text = data['username'] ?? '';
        _email = data['email'];
        _avatarUrl = data['avatar_url'];
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _message = 'Failed to load profile. Check your connection.';
      });
    }
  }

  Future<void> _pickAndUploadAvatar() async {
    final XFile? picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      imageQuality: 85,
    );
    if (picked == null) return;

    setState(() => _uploadingAvatar = true);

    try {
      final userId = supabase.auth.currentUser!.id;
      final bytes = await picked.readAsBytes();
      final ext = picked.name.contains('.') ? picked.name.split('.').last : 'jpg';
      final path = '$userId/avatar.$ext';

      await supabase.storage.from('avatars').uploadBinary(
        path,
        bytes,
        fileOptions: const FileOptions(upsert: true),
      );

      final publicUrl =
          '${supabase.storage.from('avatars').getPublicUrl(path)}?t=${DateTime.now().millisecondsSinceEpoch}';

      await supabase
          .from('profiles')
          .update({'avatar_url': publicUrl})
          .eq('id', userId);

      setState(() => _avatarUrl = publicUrl);

    } catch (e) {
      print("AVATAR ERROR: $e");

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _uploadingAvatar = false);
      }
    }
  }

  Future<void> _saveUsername() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _message = null;
    });

    try {
      final userId = supabase.auth.currentUser!.id;
      await supabase.from('profiles').update({'username': _usernameController.text.trim()}).eq('id', userId);
      setState(() => _message = 'Username updated!');
    } catch (e) {
      setState(() => _message = 'Failed to update. Try a different username.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: GestureDetector(
                  onTap: _uploadingAvatar ? null : _pickAndUploadAvatar,
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 48,
                        backgroundImage: _avatarUrl != null ? NetworkImage(_avatarUrl!) : null,
                        child: _avatarUrl == null
                            ? Text(
                          _usernameController.text.isNotEmpty
                              ? _usernameController.text[0].toUpperCase()
                              : '?',
                          style: const TextStyle(fontSize: 32),
                        )
                            : null,
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                          child: _uploadingAvatar
                              ? const SizedBox(
                            height: 14,
                            width: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                              : const Icon(Icons.camera_alt, size: 16, color: Colors.black87),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text('Email', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(_email ?? '', style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 20),
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Username cannot be empty';
                  }
                  return null;
                },
              ),
              if (_message != null) ...[
                const SizedBox(height: 12),
                Text(
                  _message!,
                  style: TextStyle(
                    color: _message == 'Username updated!' ? Colors.green : Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _saving ? null : _saveUsername,
                style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
                child: _saving
                    ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}