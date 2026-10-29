# Bootstrap a repository (no repository, or no commits)

These steps write to the user's own history, so do them only after the user has agreed in this conversation.
1. **Init.** If there is no repository, run `git init -b main` in the project directory. Never run it in a parent directory or the home directory.
2. **Identity.** Check `git config user.name` and `user.email`. If either is missing, set them repo-locally (`git config user.name/user.email`) from what the user has stated, and tell the user which values were used. Never change global git config.
3. **Write or extend `.gitignore`** (no comments in it if the project forbids comments in configuration). Inspect the untracked set with `git add -A -n . | wc -l` and with sizes, and exclude:
   - build outputs and compiled binaries, including stray ones in the repo root;
   - caches (`__pycache__/`, `*.pyc`), and LaTeX or other tool intermediates (`*.aux`, `*.log`, `*.fls`, `*.fdb_latexmk`, `*.out`, `*.toc`, `*.synctex.gz`);
   - generated experiment or run data that is large or machine-specific. Write it as a path without a trailing slash, so it also matches a symlink;
   - `/.claude/worktrees/`, `/.claude/settings.local.json`, and lock files under `.claude/`;
   - any file that holds a credential.
4. **Secret scan before the first commit.** Run `grep -rlIiE 'password|passwd|secret|token|api[_-]?key|BEGIN .*PRIVATE KEY'` over the to-be-tracked set, and check PDFs with `pdftotext`. Inspect each hit by context, without printing the secret itself. Ignore every file that holds a real credential, and tell the user which files are excluded and why. A secret that reaches a commit stays in history.
5. **Personal or unrelated files** (media, screenshots, voice notes, documents unrelated to the project): ask the user whether to move them out or ignore them. Never delete them. Move them to a sibling directory such as `~/<project>-personal/`, and check that nothing in the repo loads them by path.
6. **Review the result.** Run `git add -A -n .` again. Confirm the file count and total size are plausible and that no ignored category slipped through.
7. **First commit** on the main branch: `git add -A && git commit`, with a message that says what is included and what `.gitignore` excludes, followed by the session's attribution trailers. This is the only commit Claude makes on the main branch, and only with the user's agreement.

## Publishing a repository to GitHub

When the user asks for a GitHub remote:
1. Scan what will be published, the whole history and not only the tree: `git log -p --all | grep -ciE 'BEGIN .*PRIVATE KEY|client_secret|refresh_token|access_token|ghp_|gho_|api[_-]?key'`, plus the tree scan from step 4. Inspect hits by context without printing values.
2. Check whether the repository name already exists (`gh repo view <owner>/<name>`). If it does, read its visibility, emptiness and history before reusing it; never overwrite a non-empty one. Default to `--private`; personal configuration (hostnames, LAN addresses, email) is never public.
3. `gh repo create <owner>/<name> --private`, then `git remote add origin` with the account's SSH alias (`git@<ssh-alias>:…`).
4. Claude never pushes. Publishing follows the user's action: either the user pushes, or a versioned `post-commit`/`post-merge` hook enabled with `core.hooksPath` pushes `main` after the user's own commit or merge (the skills and chezmoi repositories work this way).
