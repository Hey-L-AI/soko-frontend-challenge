/// Result of a follow / unfollow / accept / reject action (backend PROD-2776).
///
/// Following a public account is immediate ([following] = true); a private
/// account creates a pending request ([requested] = true). [status] is
/// `active` | `pending` | null.
class FollowState {
  final bool following;
  final bool requested;
  final String? status;

  const FollowState({
    required this.following,
    this.requested = false,
    this.status,
  });

  factory FollowState.fromJson(Map<String, dynamic> json) {
    return FollowState(
      following: json['following'] as bool? ?? false,
      requested: json['requested'] as bool? ?? false,
      status: json['status'] as String?,
    );
  }
}
