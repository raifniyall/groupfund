# Backend verification

Executed against the connected Supabase project, using temporary auth users inside transactions rolled back after each test:

- A second signed-in user sees no unjoined groups.
- An outsider cannot load a known group's data.
- An invitation code allows a separate user to join the shared group.
- A member cannot create admin invitations or read owner metrics.
- Direct private table access is denied to authenticated clients.
- A message written as one user is visible through the shared group endpoint.
- A member cannot approve their own receipt.
- A group admin can access receipt evidence; an outsider cannot.
- Verification of an already-reviewed contribution is denied.
- GBP 100 with MYR 500 actually received adds MYR 500 exactly once.

JavaScript syntax validation passed. Browser UI, real email delivery, sign-in redirects, actual storage uploads and two-device end-to-end testing still need verification before replacing the demo.

Security advisors: no warning/error findings. Ten informational notices identify private tables with RLS but no policies. This is intentional: no table grants are provided, direct access is denied, and an explicitly authorized private command function is used behind an authenticated public invoker wrapper. Storage policies call scoped authorization helpers. No service-role key is exposed.
