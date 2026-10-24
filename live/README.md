# GroupFund shared application

Real frontend for the connected Supabase project. It uses the public publishable key, authenticated REST commands and private Storage. No service-role key or server credentials are included.

Copy `index.html`, `live.js`, `live.css` to `dist/` only after launch checks; reuse `dist/style.css`. The existing demo stays available meanwhile. No demo contributions should be imported.

## Launch requirements
1. Supabase Auth Site URL and allowed redirect: https://raifniyall.github.io/groupfund/
2. Configure custom SMTP for signup confirmation and password recovery. Built-in email delivery is restricted to project team addresses.
3. Confirm the owner's intended sign-in email. Add it to private `gf.owners` through the operator connection; never add it in frontend code. Access requires a confirmed email from auth.users. No first-user or browser admin switching.
4. Test actual signup/confirmation/login and upload a sample receipt with two separate accounts, group admin and member. Verify outsider denial, private file access, and shared balance refresh.
5. Publish root files through the existing GitHub Pages workflow and verify deployment.

## User functionality
Real signup, password login/recovery, groups and expiring invitation codes, fund requests and admin approval, currency-aware receipt uploads, private evidence, contributor history, group messaging, server-timed one-member voting, and owner metrics. Funds track verified receipts only. No payment execution or payout ledger is provided. Kutu is contribution planning/tracking only; schedule and recipient rotation are managed outside this release.

## Operational limits
No claim of a production audit. Browser QA and email configuration are required before launch. Shared changes refresh every 30 seconds while visible or when Refresh updates is pressed. Uploads accept PDF/JPG/PNG up to 5 MB, with bucket-level type/size restrictions. There is no malware scanning or account-deletion UI yet. Orphaned uploads require operator cleanup. Monetary records currently allow two decimal places. Review backup/retention and restore procedures before wider use.
