# Coverage pass — observations for review

No confirmed production bugs were found while adding tests. One low-confidence
**behavioral inconsistency** is worth a look (left as-is, not changed):

## InvitationsController: expiry handling differs across actions

In `lib/rhino/controllers/invitations_controller.rb`:

- `accept` (≈ line 169–177) finds a `status: "pending"` invitation **and** then
  rejects it if `invitation.expired?` (marks it `expired`, returns 422).
- `resend` (≈ line 129) and `cancel` (≈ line 154) only check
  `unless invitation.status == "pending"` — they do **not** consider
  `expires_at`. So an invitation that is still `status == "pending"` but already
  past `expires_at` can be resent (which refreshes its expiry) or cancelled.

This is arguably acceptable (resending an expired-but-pending invite to grant a
fresh window, or cancelling a stale one, are reasonable). But it is inconsistent
with `accept`, which treats an expired pending invite as no longer valid. If the
intent is "expired invitations are terminal," `resend`/`cancel` would use
`invitation.pending?` (an expiry-aware predicate) instead of the raw status
string. Flagging for a product decision, not fixing.

The existing `spec/feature/invitations_controller_spec.rb` already covers the
documented happy paths and most guards (blank email/role, already-member,
duplicate-pending, not-pending resend/cancel, invalid/expired accept), so this
file only records the observation above.
