import { useEffect, useState, type ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";
import { AnimatedText } from "./AnimatedText";
import "./ProxyMenu.css";

function StatusTag({ title, enabled }: { title: string, enabled: boolean }) {
  let additionalTags = enabled ? "border-success/40 bg-success/10 text-success" : "border-destructive/40 bg-destructive/10 text-destructive";

  let className= "inline-flex items-center rounded-md px-2 py-0.5 text-xs border font-sans font-normal normal-case shadow-none motion-safe:transition-colors motion-safe:duration-[240ms] " + additionalTags;

  return (
    <div className={className}>
      <AnimatedText title={title} animationKey={`${title}-${enabled}`} />
    </div>
  );
}

function ChipButton({ title, onClick }: { title: string, onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      className="inline-flex items-center justify-center
                 px-3 py-3 h-8 text-sm border rounded-md
                 hover:bg-accent hover:text-accent-foreground
                 whitespace-nowrap
                 disabled:pointer-events-node disabled:opacity-50
                 [&_svg]:pointer-events-none
                 bg-background
                 "
    >
      <AnimatedText title={title} />
    </button>
  );
}

function MenuRow({ title, subtitle, children }: { title: ReactNode; subtitle?: ReactNode; children?: ReactNode }) {
  return (
    <div className="border-b pt-4 pb-4">
      <div className="flex items-center justify-between gap-3">
        <div className="space-y-0.5">
          <div className="font-medium">{title}</div>

          <div className="mt-0.5 text-sm text-muted-foreground">{subtitle}</div>
        </div>

        <div>
          {children}
        </div>
      </div>
    </div>
  );
}

export function ProxyMenu() {
  const [isBridgeInstalledInApplications, setIsBridgeInstalledInApplications] = useState<boolean>(false);
  const [isBridgeInstalledInApplicationSupport, setIsBridgeInstalledInApplicationSupport] = useState<boolean>(false);
  const [isBridgeRunning, setIsBridgeRunning] = useState<boolean>(false);
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
              title={isBridgeInstalledInApplications ? "Uninstall proxy" : "Install proxy"}
              onClick={() => isBridgeInstalledInApplications ? uninstallBridge() : installBridge()}
            />
          </div>
        </MenuRow>

        <MenuRow
          title={
            <>
              Bridge installed in{" "}
              <span className="font-mono">/Applications/...</span>
            </>
          }
          subtitle={
            <>
              {/* This is where{" "}
              <span className="font-mono">Install proxy </span>
              installs into. */}

              Conductor copies the binary at this location into its{" "}
              <span className="font-mono">~/Library/Applications Support/...</span>
              directory at launch.
            </>
          }
        >
          <StatusTag
            title={isBridgeInstalledInApplications ? "Installed" : "Not installed"}
            enabled={isBridgeInstalledInApplications}
          />
        </MenuRow>

        <MenuRow
          title={
            <>
              Bridge installed in{" "}
              <span className="font-mono">~/Library/Applications Support/...</span>
            </>
          }
          subtitle={
            <>
              The location of the binary that Conductor actually uses at runtime.
              {/* If this is false and you've pressed{" "}
              <span className="font-mono">Install proxy </span>
              then restart Conductor. */}
            </>
          }
        >
          <StatusTag
            title={isBridgeInstalledInApplicationSupport ? "Installed" : "Not installed"}
            enabled={isBridgeInstalledInApplicationSupport}
          />
        </MenuRow>

        <MenuRow title="Bridge running" subtitle="">
          <StatusTag
            title={isBridgeRunning ? "Running" : "Not running"}
            enabled={isBridgeRunning}
          />
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
