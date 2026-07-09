import { ListItem, type ListItemProps } from "@expo/ui";
import { listRowSeparator } from "@expo/ui/swift-ui/modifiers";

export function ListItemPlain({ modifiers, ...props }: ListItemProps) {
  return (
    <ListItem
      modifiers={[listRowSeparator("hidden"), ...(modifiers ?? [])]}
      {...props}
    />
  );
}
