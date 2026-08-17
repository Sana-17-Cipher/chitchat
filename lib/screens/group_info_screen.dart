import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';

class GroupInfoScreen extends StatefulWidget {
  final String groupId;

  const GroupInfoScreen({super.key, required this.groupId});

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  final supabase = Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();
  late final String _currentUserId;

  String _groupName = '';
  String? _groupAvatarUrl;
  bool _isCreator = false;
  bool _uploadingAvatar = false;
  bool _loading = true;
  bool _loadingMedia = true;
  List<Map<String, dynamic>> _members = [];
  List<String> _sharedImages = [];

  @override
  void initState() {
    super.initState();
    _currentUserId = supabase.auth.currentUser!.id;
    _loadGroupInfo();
    _loadMembers();
    _loadSharedMedia();
  }

  Future<void> _loadGroupInfo() async {
    try {
      final data = await supabase.from('groups').select('name, avatar_url, created_by').eq('id', widget.groupId).single();
      if (mounted) {
        setState(() {
          _groupName = data['name'] ?? '';
          _groupAvatarUrl = data['avatar_url'];
          _isCreator = data['created_by'] == _currentUserId;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('Failed to load group info: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMembers() async {
    try {
      final response = await supabase.from('group_members').select('user_id, profiles(username, avatar_url)').eq('group_id', widget.groupId);
      final members = (response as List)
          .map((row) => {
        'user_id': row['user_id'],
        'username': row['profiles']?['username'] ?? 'Unknown',
        'avatar_url': row['profiles']?['avatar_url'],
      })
          .toList();
      if (mounted) setState(() => _members = members);
    } catch (e) {
      debugPrint('Failed to load members: $e');
    }
  }

  Future<void> _loadSharedMedia() async {
    try {
      final response = await supabase
          .from('group_messages')
          .select('image_url, image_urls')
          .eq('group_id', widget.groupId)
          .order('created_at', ascending: false);

      final images = <String>[];
      for (final row in response as List) {
        final urls = (row['image_urls'] as List?)?.cast<String>();
        if (urls != null && urls.isNotEmpty) {
          images.addAll(urls);
        } else if (row['image_url'] != null) {
          images.add(row['image_url'] as String);
        }
      }
      if (mounted) {
        setState(() {
          _sharedImages = images;
          _loadingMedia = false;
        });
      }
    } catch (e) {
      debugPrint('Failed to load group media: $e');
      if (mounted) setState(() => _loadingMedia = false);
    }
  }

  Future<void> _editGroupName() async {
    final controller = TextEditingController(text: _groupName);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Group name'),
        content: TextField(controller: controller, decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != _groupName) {
      try {
        await supabase.from('groups').update({'name': newName}).eq('id', widget.groupId);
        if (mounted) setState(() => _groupName = newName);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to update group name. Check your connection.')));
        }
      }
    }
  }

  Future<void> _pickAndUploadGroupAvatar() async {
    final XFile? picked = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 800, imageQuality: 85);
    if (picked == null) return;
    setState(() => _uploadingAvatar = true);
    try {
      final bytes = await picked.readAsBytes();
      final ext = picked.name.contains('.') ? picked.name.split('.').last : 'jpg';
      final path = 'groups/${widget.groupId}/avatar.$ext';
      await supabase.storage.from('avatars').uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: true));
      final publicUrl = '${supabase.storage.from('avatars').getPublicUrl(path)}?t=${DateTime.now().millisecondsSinceEpoch}';
      await supabase.from('groups').update({'avatar_url': publicUrl}).eq('id', widget.groupId);
      if (mounted) setState(() => _groupAvatarUrl = publicUrl);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to update group photo. Check your connection.')));
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _removeMember(String userId, String username) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $username?'),
        content: Text('$username will be removed from this group.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await supabase.from('group_members').delete().eq('group_id', widget.groupId).eq('user_id', userId);
        _loadMembers();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to remove member. Check your connection.')));
        }
      }
    }
  }

  Future<void> _openAddMembers() async {
    final currentMemberIds = _members.map((m) => m['user_id'] as String).toSet();
    List<Map<String, dynamic>> allUsers = [];
    try {
      final response = await supabase.from('profiles').select().order('username');
      allUsers = List<Map<String, dynamic>>.from(response).where((u) => !currentMemberIds.contains(u['id'])).toList();
    } catch (e) {
      debugPrint('Failed to load users to add: $e');
    }
    if (!mounted) return;

    final Set<String> selected = {};
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Add members', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 12),
                    if (allUsers.isEmpty)
                      const Padding(padding: EdgeInsets.all(16), child: Text('Everyone is already in this group.'))
                    else
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: allUsers.length,
                          itemBuilder: (context, index) {
                            final user = allUsers[index];
                            final id = user['id'] as String;
                            final avatarUrl = user['avatar_url'] as String?;
                            return CheckboxListTile(
                              value: selected.contains(id),
                              onChanged: (checked) {
                                setModalState(() {
                                  if (checked == true) {
                                    selected.add(id);
                                  } else {
                                    selected.remove(id);
                                  }
                                });
                              },
                              secondary: CircleAvatar(
                                backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                                child: avatarUrl == null ? Text((user['username'] as String).isNotEmpty ? user['username'][0].toUpperCase() : '?') : null,
                              ),
                              title: Text(user['username'] ?? 'Unknown'),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: selected.isEmpty
                          ? null
                          : () async {
                        try {
                          await supabase.from('group_members').insert(selected.map((id) => {'group_id': widget.groupId, 'user_id': id}).toList());
                          if (mounted) Navigator.pop(context);
                          _loadMembers();
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to add members. Check your connection.')));
                          }
                        }
                      },
                      child: const Text('Add selected'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave group?'),
        content: Text('You\'ll be removed from "$_groupName".'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await supabase.from('group_members').delete().eq('group_id', widget.groupId).eq('user_id', _currentUserId);
        if (mounted) {
          Navigator.pop(context);
          Navigator.pop(context);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to leave group. Check your connection.')));
        }
      }
    }
  }

  void _openFullImage(String url) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)),
      ),
    );
  }

  Widget _actionButton({required IconData icon, required String label, required VoidCallback onTap, Color? color}) {
    final resolvedColor = color ?? Theme.of(context).colorScheme.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(color: resolvedColor.withOpacity(0.15), shape: BoxShape.circle),
            child: Icon(icon, color: resolvedColor),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      body: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                  const Expanded(child: Text('Group info', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold))),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _isCreator && !_uploadingAvatar ? _pickAndUploadGroupAvatar : (_groupAvatarUrl != null ? () => _openFullImage(_groupAvatarUrl!) : null),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircleAvatar(
                    radius: 64,
                    backgroundImage: _groupAvatarUrl != null ? NetworkImage(_groupAvatarUrl!) : null,
                    child: _groupAvatarUrl == null ? const Icon(Icons.group, size: 48) : null,
                  ),
                  if (_uploadingAvatar) const CircularProgressIndicator(),
                  if (_isCreator && !_uploadingAvatar)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                        child: const Icon(Icons.camera_alt, size: 16, color: Colors.black87),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GestureDetector(
              onTap: _isCreator ? _editGroupName : null,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_groupName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  if (_isCreator) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.edit, size: 16, color: Colors.black45)),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Center(child: Text('Group · ${_members.length} members', style: const TextStyle(color: Colors.black54))),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_isCreator) ...[
                  _actionButton(icon: Icons.person_add_outlined, label: 'Add', onTap: _openAddMembers),
                  const SizedBox(width: 32),
                ],
                _actionButton(icon: Icons.exit_to_app, label: 'Leave', color: Colors.red, onTap: _leaveGroup),
              ],
            ),
            const SizedBox(height: 24),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.photo_library_outlined, size: 20, color: Colors.black54),
                  const SizedBox(width: 12),
                  const Text('Media', style: TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('${_sharedImages.length}', style: const TextStyle(color: Colors.black54)),
                ],
              ),
            ),
            if (_loadingMedia)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (_sharedImages.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Text('No shared media yet', style: TextStyle(color: Colors.black54)))
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 4, mainAxisSpacing: 4),
                  itemCount: _sharedImages.length,
                  itemBuilder: (context, index) {
                    final url = _sharedImages[index];
                    return GestureDetector(
                      onTap: () => _openFullImage(url),
                      child: ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.network(url, fit: BoxFit.cover)),
                    );
                  },
                ),
              ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('${_members.length} members', style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            ..._members.map((member) {
              final userId = member['user_id'] as String;
              final isMe = userId == _currentUserId;
              final avatarUrl = member['avatar_url'] as String?;
              return ListTile(
                leading: CircleAvatar(
                  backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                  child: avatarUrl == null ? Text((member['username'] as String).isNotEmpty ? member['username'][0].toUpperCase() : '?') : null,
                ),
                title: Text(isMe ? '${member['username']} (You)' : member['username']),
                trailing: (_isCreator && !isMe)
                    ? IconButton(icon: const Icon(Icons.remove_circle_outline, color: Colors.red), onPressed: () => _removeMember(userId, member['username']))
                    : null,
              );
            }),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}