// Member ordering shared by GroupState.activeMembers and CSV export.
// Owner: core.
import 'models.dart';

/// Display name (case-insensitive, then exact), then id.
int compareMembersByName(Member a, Member b) {
  var c = a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  if (c != 0) return c;
  c = a.displayName.compareTo(b.displayName);
  return c != 0 ? c : a.id.compareTo(b.id);
}
