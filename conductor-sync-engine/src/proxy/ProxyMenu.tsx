import { useEffect, useState, type ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./ProxyMenu.css";

function ChipButton({ title, onClick }: { title: string, onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      // inline-flex items-center justify-center whitespace-nowrap ring-offset-background focus-visible:outline-none
      // focus-visible:ring-none disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0
      // !border-input bg-background font-450 h-8
      // gap-2
      className="inline-flex items-center justify-center
                 px-3 py-3 h-8 text-sm border rounded-md
                 hover:bg-accent hover:text-accent-foreground
                 whitespace-nowrap
                 disabled:pointer-events-node disabled:opacity-50
                 [&_svg]:pointer-events-none
                 bg-background
                 "
    >
      {title}
    </button>
  );
}

function MenuRow({ title, subtitle, children }: { title: ReactNode; subtitle?: string; children?: ReactNode }) {
  return (
    <div className="border-b pt-4 pb-4">
      <div className="flex items-center justify-between gap-3">
        <div className="space-y-0.5">
          <div className="font-medium">{title}</div>

          <div className="mt-0.5 text-sm text-muted-foreground">{subtitle}</div>
        </div>

        <div>
          {children}

          {/* <button> Remove proxy </button> */}
        </div>
      </div>
    </div>
  );
}

export function ProxyMenu() {
  const [isBridgeInstalledInApplications, setIsBridgeInstalledInApplications] = useState<Boolean>(false);
  const [isBridgeInstalledInApplicationSupport, setIsBridgeInstalledInApplicationSupport] = useState<Boolean>(false);
  const [isBridgeRunning, setIsBridgeRunning] = useState<Boolean>(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  type BridgeStatus = {
    is_bridge_installed_in_applications: boolean;
    is_bridge_installed_in_application_support: boolean;
    is_bridge_reachable: boolean;
  }

  async function installBridge() {
    try {
      await invoke("install_bridge");

      await refreshBridgeStatus();
    } catch (error) {
      setErrorMessage(`Could not install bridge with error: ${error}`)
    }
  }

  async function uninstallBridge() {
    try {
      await invoke("uninstall_bridge");

      await refreshBridgeStatus();
    } catch (error) {
      setErrorMessage(`Could not uninstall bridge with error: ${error}`)
    }
  }

  async function refreshBridgeStatus() {
    try {
      const status = await invoke<BridgeStatus>("get_bridge_status");

      setIsBridgeInstalledInApplications(status.is_bridge_installed_in_applications);
      setIsBridgeInstalledInApplicationSupport(status.is_bridge_installed_in_application_support);
      setIsBridgeRunning(status.is_bridge_reachable);

      console.log("get_bridge_status: ", status);
    } catch (error) {
      console.error("Could not refresh bridge status", error);
      setErrorMessage(`Could not refresh bridge status with error: ${error}`)
    }
  }

  useEffect(() => {
    refreshBridgeStatus();

    const intervalID = window.setInterval(() => {
      refreshBridgeStatus();
    }, 500);

    return () => {
      window.clearInterval(intervalID);
    };
  }, []);

  return (
    // <div className="w-full min-w-0 space-y-6 select-text">
    <div className="">
      <h2 className="mb-2 text-2xl font-medium"> Sidecar proxy </h2>

      <div className="">
        <MenuRow title="Installation" subtitle="Install the conductor sidecar proxy to enable">
          <div className="flex items-center gap-2">
            <ChipButton
              title="Install proxy"
              onClick={() => installBridge()}
            />

            {isBridgeInstalledInApplications ? (
              <ChipButton
                title="Uninstall proxy"
                onClick={() => uninstallBridge()}
              />
            ) : null}
          </div>
        </MenuRow>

        <MenuRow
          title={
            <>
              Is bridge installed in{" "}
              <span className="font-mono">/Applications/...</span>
            </>
          }
        >
          {isBridgeInstalledInApplications ? "Yes" : "No"}
        </MenuRow>

        <MenuRow
          title={
            <>
              Is bridge installed in{" "}
              <span className="font-mono">~/Library/Applications Support/...</span>
            </>
          }
        >
          {isBridgeInstalledInApplicationSupport ? "Yes" : "No"}
        </MenuRow>

        <MenuRow title="Is bridge running">
          {isBridgeRunning ? "Yes" : "No"}
        </MenuRow>

        {errorMessage != null ? (
          <MenuRow title="Error">
            {errorMessage ?? ""}
          </MenuRow>
        ) : null}
      </div>
    </div>
  );
}