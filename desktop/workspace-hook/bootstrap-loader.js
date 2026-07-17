(() => {

  const serverURL = new URL("http://127.0.0.1:3769/");
  const hookURL = new URL("workspace-ui-hook/hook.js", serverURL);

  // Get the actual hook script from the desktop app (browser-hook.mjs)
  void fetch(hookURL, { cache: "no-store" }) // Don't cache it (for updates)
    .then((response) => {
      if (!response.ok) throw new Error("Could not load the Workspace UI Hook.");

      const revision = response.headers.get("ETag");
      if (!revision) throw new Error("The Workspace UI Hook revision is missing.");

      hookURL.searchParams.set("revision", revision);
      return import(hookURL.href);
    })
    .then((module) => module.prepareWorkspaceUIHook())
    .catch((error) => {
      console.error(
        "Conductor Mobile could not connect the Workspace UI Hook.",
        error,
      );
    });
})();
