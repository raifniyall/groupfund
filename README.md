# GroupFund — friends & family prototype

A responsive, buildless prototype for group savings. Serve `dist/` with any static web host, or run `python3 -m http.server 8080 --directory dist`.

## Test journeys
- Overview, group creation/join (code `TOGETHER`), optional invitation simulation.
- Fund creation/join requests; switch to admin to approve.
- External contribution simulation, receipt reference, admin verification and balance update.
- Expense voting, 3–14 days/default 7, one vote per demo member. Admin deadline simulation.
- Withdrawal approval and admin confirmation of external payments.
- Privacy preferences, notifications, local group messaging and reset.

## Prototype limits
No backend, real authentication, bank integration, email delivery or shared multi-user data. State is stored in each browser's localStorage. Do not enter private financial data or transfer real money. Admin/member switching is a testing aid, not access control. Vote tally uses a simple demo majority; production quorum and eligibility policy need definition. Receipt references are simulated, not uploaded documents.

Production requires secure authentication/authorization, shared database, private file storage, audit trails, notification delivery, server-enforced eligibility and voting deadlines, and transactional financial bookkeeping.
