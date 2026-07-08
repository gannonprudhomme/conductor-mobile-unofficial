import type { ReactNode } from "react";
import "./ProxyMenu.css";

function ChipButton({title, onClick}: {title: string, onClick: () => void}) {
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

function MenuRow({title, subtitle, children}: {title: string; subtitle: string; children?: ReactNode}) {
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
  return (
    // <div className="w-full min-w-0 space-y-6 select-text">
    <div className="">
      <h2 className="mb-2 text-2xl font-medium"> Sidecar proxy </h2>

      <div className="">
        <MenuRow title="Installation" subtitle="Install the conductor sidecar proxy to enable">
          <ChipButton
            title="Install proxy"
            onClick={() => console.log("Clicked!")}
          />
        </MenuRow>
      </div>
    </div>
  );
}