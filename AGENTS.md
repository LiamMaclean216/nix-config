# Local development environment

This host runs NixOS. Node.js, Docker, Chromium, ripgrep, jq, fd, and
ShellCheck are managed by Nix. Use the repository's pinned dependencies
and documented commands; do not install a global Playwright or use
`playwright install --with-deps` on this host.

For local browser scripts, use the Nix-managed browser selected by
CHROMIUM_EXECUTABLE (or chromium on PATH). Playwright scripts must pass
that path as their launch executablePath; the variable is a convention,
not an automatic Playwright setting. Use the repository's documented
container workflow when matching browser versions or multiple engines
are required.

Diagnose browser launch failures before installing dependencies.
Distinguish sandbox restrictions from missing binaries or shared libraries,
and use the normal approval flow when an operation requires it.
Validate with the smallest relevant checks and report what actually ran.
Follow repository guidance for test selection and starting local services.

# Desktop preview windows

Open visual preview and test windows on the last workspace or a dedicated
unused workspace, using silent/background placement. Keep the user's current
workspace and keyboard focus unchanged so previews do not interrupt their work.
Close only the preview windows you created when finished.
