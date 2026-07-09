import { List } from "@expo/ui";
import type { ReactNode } from "react";

type ListPlainProps = {
  children?: ReactNode;
};

export function ListPlain({ children }: ListPlainProps) {
  return <List>{children}</List>;
}
