import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ContactInfoScreen extends StatefulWidget {
  final String userId;
  final String username;

  const ContactInfoScreen({super.key, required this.userId, required this.username});

  @override
  State<ContactInfoScreen> createState() => _ContactInfoScreenState();
}

class _ContactInfoScreenState extends State<ContactInfoScreen> {
  final supabase = Supabase.instance.client;
  late final Stream<Map<String, dynamic>?> _statusStream;
  List<String> _sharedImages = [];
  bool _loadingMedia = true;
  bool _isBlockedByMe = false;

  @override
  void initState() {
    super.initState();
    _statusStream = supabase
        .from('profiles')
        .stream(primaryKey: ['id'])
        .eq('id', widget.userId)
        .map((rows) => rows.isNotEmpty ? rows.first : null);
    _loadSharedMedia();
    _checkBlockStatus();
  }

  Future<void> _checkBlockStatus() async {
    final currentUserId = supabase.auth.currentUser!.id;
    try {
      final data = await supabase
          .from('blocked_users')
          .select()
          .eq('blocker_id', currentUserId)
          .eq('blocked_id', widget.userId)
          .maybeSingle();
      if (mounted) setState(() => _isBlockedByMe = data != null);
    } catch (e) {
      debugPrint('Failed to check block status: $e');
    }
  }

  Future<void> _toggleBlock() async {
    final currentUserId = supabase.auth.currentUser!.id;
    if (_isBlockedByMe) {
      await supabase.from('blocked_users').delete().eq('blocker_id', currentUserId).eq('blocked_id', widget.userId);
      if (mounted) setState(() => _isBlockedByMe = false);
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Block ${widget.username}?'),
          content: const Text('They won\'t be able to send you messages anymore.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Block')),
          ],
        ),
      );
      if (confirmed == true) {
        await supabase.from('blocked_users').insert({'blocker_id': currentUserId, 'blocked_id': widget.userId});
        if (mounted) setState(() => _isBlockedByMe = true);
      }
    }
  }

  Future<void> _reportUser() async {
    String? selectedReason;
    final detailsController = TextEditingController();
    final currentUserId = supabase.auth.currentUser!.id;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Report ${widget.username}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...['Spam', 'Harassment', 'Inappropriate content', 'Other'].map(
                      (reason) => RadioListTile<String>(
                    value: reason,
                    groupValue: selectedReason,
                    title: Text(reason),
                    onChanged: (value) => setDialogState(() => selectedReason = value),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: detailsController,
                  decoration: const InputDecoration(labelText: 'Additional details (optional)', border: OutlineInputBorder()),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: selectedReason == null ? null : () => Navigator.pop(context, true), child: const Text('Submit')),
          ],
        ),
      ),
    );

    if (confirmed == true && selectedReason != null) {
      try {
        await supabase.from('user_reports').insert({
          'reporter_id': currentUserId,
          'reported_id': widget.userId,
          'reason': detailsController.text.trim().isEmpty ? selectedReason : '$selectedReason: ${detailsController.text.trim()}',
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report submitted. Thank you for helping keep ChitChat safe.')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to submit report. Check your connection.')));
        }
      }
    }
  }

  Future<void> _loadSharedMedia() async {
    final currentUserId = supabase.auth.currentUser!.id;
    try {
      final response = await supabase
          .from('messages')
          .select('image_url, image_urls')
          .or('and(sender_id.eq.$currentUserId,receiver_id.eq.${widget.userId}),and(sender_id.eq.${widget.userId},receiver_id.eq.$currentUserId)')
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
      debugPrint('Failed to load shared media: $e');
      if (mounted) setState(() => _loadingMedia = false);
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
    return Scaffold(
      body: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                  const Expanded(
                    child: Text('Contact info', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            const SizedBox(height: 8),
            StreamBuilder<Map<String, dynamic>?>(
              stream: _statusStream,
              builder: (context, snapshot) {
                final data = snapshot.data;
                final avatarUrl = data?['avatar_url'] as String?;
                final isOnline = data?['online'] == true;

                return Column(
                  children: [
                    GestureDetector(
                      onTap: avatarUrl != null ? () => _openFullImage(avatarUrl) : null,
                      child: CircleAvatar(
                        radius: 64,
                        backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                        child: avatarUrl == null
                            ? Text(widget.username.isNotEmpty ? widget.username[0].toUpperCase() : '?', style: const TextStyle(fontSize: 44))
                            : null,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(widget.username, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(isOnline ? 'Online' : 'Offline', style: TextStyle(color: isOnline ? Colors.green : Colors.black54)),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _actionButton(icon: Icons.flag_outlined, label: 'Report', onTap: _reportUser),
                        const SizedBox(width: 32),
                        _actionButton(
                          icon: _isBlockedByMe ? Icons.person_add_outlined : Icons.block,
                          label: _isBlockedByMe ? 'Unblock' : 'Block',
                          color: Colors.red,
                          onTap: _toggleBlock,
                        ),
                      ],
                    ),
                  ],
                );
              },
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
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}