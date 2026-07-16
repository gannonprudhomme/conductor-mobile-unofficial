(() => {
  // Keep the saved snippet tiny by leaving discovery, SSE, and service calls in the hook module.
  const loaderGenerationKey = "__conductorMobileWorkspaceUIHookLoaderRun";
  const serverURL = new URL("http://127.0.0.1:3769/");
  const generation = crypto.randomUUID();
  const hookURL = new URL("workspace-ui-hook/hook.js", serverURL);
  // Cache-bust each import and publish its generation so only the latest run can install itself.
  hookURL.searchParams.set("generation", generation);
  globalThis[loaderGenerationKey] = generation;

  void import(hookURL.href)
    .then((module) => module.prepareWorkspaceUIHook(generation))
    .catch((error) => {
      // Do not surface a late failure from a loader run the user has already superseded.
      if (globalThis[loaderGenerationKey] !== generation) return;

      console.error(
        "Conductor Mobile could not connect the Workspace UI Hook. Run the saved Conductor Mobile snippet again.",
        error,
      );
    });
})();
