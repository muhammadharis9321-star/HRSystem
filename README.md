# Muster: free leave and approvals (starter)

Covers: companies, people and roles, leave balances, leave requests, manager approvals. All on free tiers, no card needed.

1. Create a free project at supabase.com.
2. SQL Editor: paste all of `schema.sql` and run it.
3. Authentication > Providers > Email: switch off "Confirm email" while testing (optional).
4. Project Settings > API: copy the Project URL and anon key into the top of `index.html`.
5. Test locally: `python -m http.server 8000` in this folder, open http://localhost:8000
6. Deploy free: push the folder to GitHub, then Cloudflare Pages > connect repo. No build command; output directory is the repo root.
7. First user: Create account, then "Start a company" (you become admin). Share the join code with staff, then set roles and approvers under People.

Free Supabase projects pause after a week of inactivity. A scheduled GitHub Action that calls
`$SUPABASE_URL/rest/v1/organizations?select=id&limit=1` with header `apikey: $SUPABASE_ANON_KEY` every few days should keep it awake.

Approval rules: an employee's request goes to their assigned approver, or to any admin. Nobody can decide their own request, so a company needs at least two admins or an admin who is someone else's approver.
