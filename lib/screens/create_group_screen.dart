import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'group_chat_screen.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final supabase = Supabase.instance.client;
  final _nameController = TextEditingController();
  List<Map<String, dynamic>> _users = [];
  final Set<String> _selectedIds = {};
  bool _loading = true;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    final currentUserId = supabase.auth.currentUser!.id;
    debugPrint("Current User ID: $currentUserId");

    try {
      final response = await supabase.from('profiles').select().neq('id', currentUserId).order('username');
      setState(() {
        _users = List<Map<String, dynamic>>.from(response);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to load users.';
      });
    }
  }

  Future<void> _createGroup() async {

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a group name');
      return;
    }
    if (_selectedIds.length < 2) {
      setState(() => _error = 'Select at least 2 members');
      return;
    }

    setState(() {
      _creating = true;
      _error = null;
    });

    try {
      final currentUserId = supabase.auth.currentUser!.id;


      debugPrint("Current User ID: $currentUserId");
      debugPrint("Creating group:");
      debugPrint({
        'name': name,
        'created_by': currentUserId,
      }.toString());

      final groupResponse = await supabase
          .from('groups')
          .insert({
        'name': name,
        'created_by': currentUserId,
      })
          .select()
          .single();
      final groupId = groupResponse['id'];

      final memberRows = [
        {'group_id': groupId, 'user_id': currentUserId},
        ..._selectedIds.map((id) => {'group_id': groupId, 'user_id': id}),
      ];
      await supabase.from('group_members').insert(memberRows);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => GroupChatScreen(groupId: groupId, groupName: name)),
        );
      }
    } catch (e) {
      debugPrint("CREATE GROUP ERROR: $e");

      setState(() {
        _error = e.toString();
        _creating = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New group')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Group name',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(alignment: Alignment.centerLeft, child: Text('Select members')),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
              itemCount: _users.length,
              itemBuilder: (context, index) {
                final user = _users[index];
                final id = user['id'] as String;
                final avatarUrl = user['avatar_url'] as String?;
                final selected = _selectedIds.contains(id);
                return CheckboxListTile(
                  value: selected,
                  onChanged: (checked) {
                    setState(() {
                      if (checked == true) {
                        _selectedIds.add(id);
                      } else {
                        _selectedIds.remove(id);
                      }
                    });
                  },
                  secondary: CircleAvatar(
                    backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                    child: avatarUrl == null
                        ? Text((user['username'] as String).isNotEmpty
                        ? user['username'][0].toUpperCase()
                        : '?')
                        : null,
                  ),
                  title: Text(user['username'] ?? 'Unknown'),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _creating ? null : _createGroup,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
                  child: _creating
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Create group'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}