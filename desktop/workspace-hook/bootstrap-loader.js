(() => {
  // Keep the saved snippet tiny by leaving discovery, SSE, and service calls in the hook module.
  const serverURL = new URL("http://127.0.0.1:3769/");
  const hookURL = new URL("workspace-ui-hook/hook.js", serverURL);
  hookURL.searchParams.set("cache", crypto.randomUUID());

  void import(hookURL.href) // Fetch the larger `browser-hook` file (so you only have to paste this script once)
    .then((module) => module.prepareWorkspaceUIHook()) // Run `prepareWorkspaceUIHook()` from `browser-hook.mjs` in this repo
    .catch((error) => {
      console.error(
        "Conductor Mobile could not connect the Workspace UI Hook.",
        error,
      );
    });
})();
