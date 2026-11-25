# Code-review inline comments — gh + glab API reference

Shared reference for inline (positioned) code-review comments across **GitHub PRs** and
**GitLab MRs**, plus a **local-doc fallback** for when there is no PR/MR. Embedded by
tickets **SCR-1** (smart-code-review writer) and **ACR-1** (apply-comments reader).

Each platform section gives copy-pasteable, read-only-verified commands for the three
operations every consumer needs:

- **POST** an inline comment on a specific `file` + `line`
- **LIST** all existing review comments (with `file`, `line`, `body`, `author`,
  `resolved`-state, and a `thread`/`discussion` id)
- **REPLY** to a specific inline comment thread

> **Tooling assumed:** `gh` 2.88, `glab` 1.99, `jq`. No third-party libraries. Prefer the
> raw REST surface (`gh api` / `glab api`) over higher-level subcommands when the
> subcommand cannot target a line — `gh pr review` and `glab mr note` cannot pin a
> file+line, so inline posting always goes through `*api`.

---

## 0. Platform detection (from origin remote)

Pick the tool from the host of `git remote get-url origin`:

```bash
origin_host=$(git remote get-url origin 2>/dev/null \
  | sed -E 's#^(https?://|git@)([^/:]+).*#\2#')

case "$origin_host" in
  github.com|*.github.com)  platform=github ;;   # use gh
  gitlab.com|gitlab.*)      platform=gitlab ;;   # use glab  (covers gitlab.cloudokyo.dev)
  *)                        platform=local  ;;   # no PR/MR host -> local-doc fallback (see §3)
esac
echo "$platform"
```

- A GitHub host (`github.com`, GHES `*.github.com`) ⇒ **`gh`**.
- Any GitLab host — including self-managed `gitlab.cloudokyo.dev` — ⇒ **`glab`**, passing
  `--hostname <host>` to `glab api` for non-`gitlab.com` instances.
- Anything else (no recognized forge, or no remote) ⇒ the **local-doc fallback** in §3.

The `sed` extracts the host from both `https://host/owner/repo` and `git@host:owner/repo`
forms.

---

## 1. GitHub (Pull Request review comments)

GitHub calls inline comments **review comments** (`repos/:owner/:repo/pulls/:n/comments`),
distinct from issue-style PR comments (`.../issues/:n/comments`). Resolved-state and the
thread id are **only** exposed via GraphQL `reviewThreads`, not via REST.

### 1a. Get the ids you need

```bash
# Auth check (read-only)
gh auth status

# PR number + head commit SHA + base/head refs for the current branch:
gh pr view --json number,headRefOid,baseRefName,headRefName,url
#   .number      -> :n
#   .headRefOid  -> commit_id for a new review comment (must be the latest commit SHA)
```

`gh pr view --json` accepts (among others): `number`, `headRefOid`, `baseRefName`,
`headRefName`, `url`, `reviews`, `comments`, `files`, `commits`. (Field list verified by
`gh pr view <n> --json <bad>` which prints the available set.)

### 1b. POST an inline comment on file+line

`gh pr review` **cannot** target a line (it only has `--approve/--comment/--request-changes
-b <body>`, verified via `gh pr review --help`), so post via `gh api`:

```bash
gh api --method POST "repos/{owner}/{repo}/pulls/<n>/comments" \
  -f body="<comment text>" \
  -f commit_id="<HEAD_SHA>" \      # = headRefOid from §1a
  -f path="src/foo.ts" \
  -F line=42 \                     # -F = typed field -> integer
  -f side="RIGHT"                  # RIGHT = new version; LEFT = old
# Multi-line range: add  -F start_line=38 -f start_side="RIGHT"
```

`{owner}`/`{repo}` are auto-filled from the cwd repo (or set `GH_REPO`). Endpoint, params
(`body`, `commit_id`, `path`, `line`, `side`, `start_line`) per REST docs
`POST /repos/{owner}/{repo}/pulls/{pull_number}/comments`.

### 1c. LIST all review comments (file, line, body, author, thread, resolved)

REST gives file/line/body/author/thread-linkage:

```bash
gh api "repos/{owner}/{repo}/pulls/<n>/comments" --paginate \
  --jq '.[] | {
    id,                       # review-comment id (REST databaseId)
    in_reply_to_id,           # set => this is a reply in a thread
    review_id: .pull_request_review_id,
    file: .path,
    line: (.line // .original_line),
    side,
    commit_id,
    author: .user.login,
    body
  }'
```

Verified live (read-only) against `repos/cli/cli/pulls/9000/comments` — real fields
returned: `id`, `in_reply_to_id`, `pull_request_review_id`, `path`, `line`,
`original_line`, `start_line`, `side`, `commit_id`, `original_commit_id`, `user.login`,
`body`. (`line` is `null` on outdated comments — fall back to `original_line`.)

REST does **not** expose `resolved` or a stable thread id for review comments. Get those
from GraphQL `reviewThreads`:

```bash
gh api graphql -f owner='{owner}' -f repo='{repo}' -F num=<n> -f query='
query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$num){
      reviewThreads(first:100){
        nodes{
          id                       # stable thread id (e.g. PRRT_...)
          isResolved
          isOutdated
          path
          line
          comments(first:100){ nodes{
            databaseId             # == REST comment id
            author{login}
            body
          }}
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | {
  thread_id: .id, resolved: .isResolved, outdated: .isOutdated,
  file: .path, line, comments: [.comments.nodes[] | {id: .databaseId, author: .author.login, body}]
}'
```

Verified live against `cli/cli#9000`: returns `isResolved` (true/false), thread `id`
(`PRRT_...`), and `comments.nodes[].databaseId` matching the REST comment ids — this is
the join key between the two queries.

### 1d. REPLY to a specific thread

Reply by pointing a new review comment at the root comment's id via `in_reply_to`:

```bash
gh api --method POST "repos/{owner}/{repo}/pulls/<n>/comments" \
  -f body="<reply text>" \
  -F in_reply_to=<root_comment_id>   # the REST id / databaseId of the comment to reply to
```

Per REST `POST .../pulls/{pull_number}/comments` with `in_reply_to`. Use the `id` from §1c
REST output (or `databaseId` from GraphQL) of the **first** comment in the thread.

---

## 2. GitLab (Merge Request discussions)

GitLab calls inline-comment threads **discussions**. A positioned discussion carries a
`position` object whose SHAs come from the MR's diff refs.

> **Live-verification status for this section:** the `glab` token for
> `gitlab.cloudokyo.dev` was **expired** at authoring time — `glab auth status` reported
> `gitlab.cloudokyo.dev: 401 invalid_token / Token is expired`, and a read-only
> `glab api projects/Quincy%2Fads/merge_requests/1213/discussions --hostname
> gitlab.cloudokyo.dev` returned **HTTP 401** (no data, no write performed). The commands
> below are therefore **doc-sourced** from the official GitLab Discussions + Merge Requests
> REST docs (https://docs.gitlab.com/api/discussions/ and /api/merge_requests/), not live
> against MR 1213. Re-run them after `glab auth login --hostname gitlab.cloudokyo.dev` to
> confirm field shapes on the real instance.

### 2a. Get project id, iid, and the position SHAs

```bash
# Auth check (read-only)
glab auth status

# project_id + iid for the current branch's MR (text|json output):
glab mr view --output json | jq '{project_id, iid, web_url}'
#  glab mr view flags verified via `glab mr view --help`: -F/--output text|json
```

The `position` object needs three SHAs. Two read-only ways to obtain them, both GET:

**Option A — `diff_refs` on the MR (simplest):**

```bash
glab api "projects/:id/merge_requests/<iid>" --hostname <host> \
  | jq '.diff_refs'        # -> { base_sha, head_sha, start_sha }
```

`diff_refs` maps 1:1 onto the position fields: `base_sha`→`position[base_sha]`,
`head_sha`→`position[head_sha]`, `start_sha`→`position[start_sha]`. (Per
`GET /projects/:id/merge_requests/:merge_request_iid`, `diff_refs` object.)

**Option B — `/versions` (the ticket-required route):**

```bash
glab api "projects/:id/merge_requests/<iid>/versions" --hostname <host> \
  | jq '.[0] | {base_sha: .base_commit_sha, head_sha: .head_commit_sha, start_sha: .start_commit_sha}'
```

`GET /projects/:id/merge_requests/:merge_request_iid/versions` returns an array of diff
versions; the newest (`.[0]`) carries `base_commit_sha`, `head_commit_sha`,
`start_commit_sha`, which feed `position[base_sha]`, `position[head_sha]`,
`position[start_sha]` respectively.

> `:id` placeholder is auto-filled by `glab api` from the cwd repo; otherwise URL-encode the
> path, e.g. `projects/Quincy%2Fads`.

### 2b. POST a positioned (inline) comment on file+line

`glab mr note` cannot target a line, so post a discussion with a `position` via `glab api`:

```bash
glab api --method POST "projects/:id/merge_requests/<iid>/discussions" --hostname <host> \
  -f body="<comment text>" \
  -f position[position_type]=text \
  -f position[base_sha]=<BASE_SHA> \      # from §2a
  -f position[head_sha]=<HEAD_SHA> \
  -f position[start_sha]=<START_SHA> \
  -f position[new_path]="src/foo.ts" \
  -f position[old_path]="src/foo.ts" \
  -f position[new_line]=42                # line in the new version; use position[old_line] for a deleted line
```

Per `POST /projects/:id/merge_requests/:merge_request_iid/discussions`. **Required position
fields** for a text diff note: `base_sha`, `head_sha`, `start_sha`, `position_type=text`,
`new_path`, `old_path`. **Line fields:** `new_line` (line after change) and/or `old_line`
(line before change) — at least one required to anchor the comment.

### 2c. LIST all discussions (file, line, body, author, resolved, discussion id)

```bash
glab api "projects/:id/merge_requests/<iid>/discussions" --hostname <host> --paginate \
  | jq '.[] | {
      discussion_id: .id,                         # stable thread id (40-char hash)
      notes: [ .notes[] | {
        note_id:  .id,
        author:   .author.username,
        body:     .body,
        resolved: .resolved,                       # true|false (MR notes only)
        resolvable: .resolvable,
        file:     (.position.new_path // .position.old_path),
        line:     (.position.new_line // .position.old_line)
      }]
    }'
```

Per `GET /projects/:id/merge_requests/:merge_request_iid/discussions`. Each discussion has
`id` (the thread id) and a `notes[]` array; each note exposes `id`, `body`,
`author.username`, `resolved`, `resolvable`, and (for diff notes) a `position` object with
`new_path`/`old_path` and `new_line`/`old_line`. Non-diff (general) notes have
`position: null`.

### 2d. REPLY to a specific discussion

```bash
glab api --method POST \
  "projects/:id/merge_requests/<iid>/discussions/<discussion_id>/notes" --hostname <host> \
  -f body="<reply text>"
```

Per `POST /projects/:id/merge_requests/:merge_request_iid/discussions/:discussion_id/notes`.
`<discussion_id>` is the `.id` of the discussion from §2c.

---

## 3. Local-doc fallback schema

Used when §0 detection yields `local` (no recognized PR/MR host) — review findings are
written to a file in the repo instead of a forge. ACR-1 re-parses this file to re-find each
finding's `file`, `line`, `body`, and stable `id`.

**Canonical path (relative to the repo root being reviewed):**

```
.code-review/inline-comments.md
```

(`SCR-1` creates the dir; `ACR-1` reads from the same path. One file per review pass; if a
prior file exists, ACR-1 matches on `id` to carry `status`/`reply` forward.)

**Format:** YAML front-matter for run metadata, then one fenced `yaml` block per finding.
Each finding block is independently parseable and keyed by a stable `id`.

```markdown
---
schema: code-review-inline/v1
platform: local
repo: /Users/haimengzhou/apps/ads
commit: <git rev-parse HEAD>
generated_at: 2026-06-30T00:00:00Z
---

# Inline review findings

```yaml
id: f-0001                     # stable id: f-<4 digits>, never reused within a run
file: src/foo.ts               # path relative to repo root
line: 42                       # 1-based line in the working tree at `commit`
severity: bug                  # bug | security | perf | style | nit
body: |
  Off-by-one: loop should stop at `len - 1`, this reads past the slice end.
status: open                   # open | resolved | wontfix
reply:                         # filled by ACR-1 / human; empty until then
```

```yaml
id: f-0002
file: src/auth.ts
line: 113
severity: security
body: |
  Token compared with `==`; use a constant-time compare to avoid timing leaks.
status: open
reply: |
  Fixed in follow-up — switched to crypto.timingSafeEqual.
```
```

**Stable-id rule:** `id` is assigned once on first write (`f-0001`, `f-0002`, …) and is the
join key for re-finding a comment across runs — file/line may drift as code changes, but
`id` is durable. The `reply`/`status` slots let a second pass record resolution without
losing the original finding.

**Field contract (every finding block):** `id`, `file`, `line`, `severity`, `body`,
`status`, `reply`. `body` and `reply` use YAML block scalars (`|`) to allow multi-line
text. ACR-1 parses each ```` ```yaml ```` block independently.

---

## Verification provenance

| Item | How verified |
|------|--------------|
| `gh` 2.88.1 / `glab` 1.99.0 present, `gh` authed (`AmenZhou`) | `gh --version`, `glab --version`, `gh auth status` |
| GitHub REST review-comment fields (`path`,`line`,`original_line`,`side`,`commit_id`,`id`,`in_reply_to_id`,`pull_request_review_id`,`user.login`,`body`) | **live read-only** GET `repos/cli/cli/pulls/9000/comments` |
| GitHub GraphQL `reviewThreads` (`isResolved`, thread `id`, `comments.databaseId`) | **live read-only** GraphQL against `cli/cli#9000` |
| `gh pr review` cannot target a line; `gh pr view --json` field set | `gh pr review --help`, `gh pr view <n> --json <bad>` |
| GitLab discussions/versions endpoints + `position` fields + `diff_refs` | official REST docs (docs.gitlab.com `/api/discussions/`, `/api/merge_requests/`) — **doc-sourced** |
| MR 1213 live check | **attempted, blocked:** `glab` token for `gitlab.cloudokyo.dev` expired → HTTP 401; no write performed |
| `glab api` flags (`--hostname`,`--method`,`-f/--field`), `glab mr view -F json` | `glab api --help`, `glab mr view --help` |

No flags in this doc were invented; every command maps to a `--help`-confirmed flag or an
official REST endpoint. **No PR/MR was mutated** — all live calls were GET/GraphQL reads.
