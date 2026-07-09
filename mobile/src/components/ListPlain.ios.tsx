import { List } from "@expo/ui/swift-ui";
import { listStyle } from "@expo/ui/swift-ui/modifiers";
import type { ReactNode } from "react";

type ListPlainProps = {
  children?: ReactNode;
};

export function ListPlain({ children }: ListPlainProps) {
  return <List modifiers={[listStyle("plain")]}>{children}</List>;
}
