// 100% written by codex

import { useLayoutEffect, useRef, useState } from "react";

export function AnimatedText({
  title,
  animationKey = title,
}: {
  title: string;
  animationKey?: string;
}) {
  const titleRef = useRef<HTMLSpanElement>(null);
  const [width, setWidth] = useState<number>();

  // Text has an intrinsic width, so measure the rendered label and transition
  // the outer wrapper between concrete pixel widths.
  useLayoutEffect(() => {
    const nextWidth = titleRef.current?.getBoundingClientRect().width;
    if (nextWidth != null) {
      setWidth(nextWidth);
    }
  }, [animationKey]);

  return (
    <span
      className="inline-block overflow-hidden align-bottom motion-safe:transition-[width] motion-safe:duration-[240ms] motion-safe:ease-out"
      style={width == null ? undefined : { width }}
    >
      <span
        ref={titleRef}
        // Replacing the inner span makes the CSS animation replay when the
        // title, or any caller-provided state in animationKey, changes.
        key={animationKey}
        className="inline-block whitespace-nowrap motion-safe:animate-[chip-title-change_240ms_ease-out]"
      >
        {title}
      </span>
    </span>
  );
}
