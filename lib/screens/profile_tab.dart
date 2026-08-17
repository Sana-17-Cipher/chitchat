import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'profile_screen.dart';

class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  final supabase = Supabase.instance.client;
  String? _username;
  String? _email;
  String? _avatarUrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final userId = supabase.auth.currentUser!.id;
    try {
      final data = await supabase.from('profiles').select().eq('id', userId).single();
      if (mounted) {
        setState(() {
          _username = data['username'];
          _email = data['email'];
          _avatarUrl = data['avatar_url'];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signOut() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId != null) {
      await supabase.from('profiles').update({
        'online': false,
        'last_seen': DateTime.now().toIso8601String(),
      }).eq('id', userId);
    }
    await supabase.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: CircleAvatar(
            radius: 48,
            backgroundImage: _avatarUrl != null ? NetworkImage(_avatarUrl!) : null,
            child: _avatarUrl == null
                ? Text(_username?.isNotEmpty == true ? _username![0].toUpperCase() : '?', style: const TextStyle(fontSize: 32))
                : null,
          ),
        ),
        const SizedBox(height: 12),
        Center(child: Text(_username ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
        Center(child: Text(_email ?? '', style: const TextStyle(color: Colors.black54))),
        const SizedBox(height: 24),
        Card(
          child: ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit profile'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()));
              _loadProfile();
            },
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Sign out', style: TextStyle(color: Colors.red)),
            onTap: _signOut,
          ),
        ),
      ],
    );
  }
}