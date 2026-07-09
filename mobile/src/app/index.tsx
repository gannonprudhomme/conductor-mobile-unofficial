import { Collapsible, Host } from "@expo/ui";
import { Stack } from "expo-router";
import { useState, type ReactNode } from "react";
import type { ImageSourcePropType } from "react-native";
import { StyleSheet, View } from "react-native";

import { ListItemPlain } from "../components/ListItemPlain";
import { ListPlain } from "../components/ListPlain";
import LucideEllipsis from "../assets/toolbar-icons/lucide_ellipsis.xml";
import LucidePlus from "../assets/toolbar-icons/lucide_plus.xml";
import LucideSettings from "../assets/toolbar-icons/lucide_settings.xml";
import Workspaces from "./workspaces";

type ToolbarIconProps = {
  android: ImageSourcePropType;
  ios: string;
};

function toolbarIcon({ ios }: ToolbarIconProps) {
  if (process.env.EXPO_OS !== "ios") {
    return null;
  }

  return <Stack.Toolbar.Icon renderingMode="template" xcasset={ios} />;
}

function toolbarButtonIcon({ android }: ToolbarIconProps) {
  return process.env.EXPO_OS === "ios" ? undefined : android;
}

function toolbarMenuIcon({ android }: ToolbarIconProps) {
  return process.env.EXPO_OS === "ios" ? undefined : android;
}

type CollapsibleSectionProps = {
  children: ReactNode;
  count?: number;
  defaultExpanded?: boolean;
  title: string;
};

function CollapsibleSection({
  children,
  count,
  defaultExpanded = true,
  title,
}: CollapsibleSectionProps) {
  const [isExpanded, setIsExpanded] = useState(defaultExpanded);
  const label = count == null ? title : `${title} ${count}`;

  return (
    <Collapsible
      isOpen={isExpanded}
      label={label}
      onOpenChange={setIsExpanded}
    >
      {children}
    </Collapsible>
  );
}

/*
export default function Index() {
  return (
    <>
      <Stack.Toolbar placement="right">
        <Stack.Toolbar.Button
          accessibilityLabel="Add"
          icon={toolbarButtonIcon({ android: LucidePlus, ios: "lucide_plus" })}
          onPress={() => {}}
        >
          {toolbarIcon({ android: LucidePlus, ios: "lucide_plus" })}
        </Stack.Toolbar.Button>
        <Stack.Toolbar.Menu
          accessibilityLabel="More"
          icon={toolbarMenuIcon({
            android: LucideEllipsis,
            ios: "lucide_ellipsis",
          })}
        >
          {toolbarIcon({
            android: LucideEllipsis,
            ios: "lucide_ellipsis",
          })}
          <Stack.Toolbar.MenuAction
            icon={toolbarMenuIcon({
              android: LucideSettings,
              ios: "lucide_settings",
            })}
            onPress={() => {}}
          >
            {toolbarIcon({ android: LucideSettings, ios: "lucide_settings" })}
            <Stack.Toolbar.Label>Settings</Stack.Toolbar.Label>
          </Stack.Toolbar.MenuAction>
        </Stack.Toolbar.Menu>
      </Stack.Toolbar>

      <View style={styles.container}>
        <Host style={styles.host}>
          <ListPlain>
            <CollapsibleSection count={1} title="Done">
              <ListItemPlain>Main</ListItemPlain>
            </CollapsibleSection>
            <CollapsibleSection title="In review">
              <ListItemPlain>Main</ListItemPlain>
            </CollapsibleSection>
            <CollapsibleSection title="In progress">
              <ListItemPlain>Main</ListItemPlain>
            </CollapsibleSection>
            <CollapsibleSection count={11} defaultExpanded={false} title="Backlog">
              <ListItemPlain>Main</ListItemPlain>
            </CollapsibleSection>
            <CollapsibleSection title="Canceled">
              <ListItemPlain>Main</ListItemPlain>
              <ListItemPlain>Master</ListItemPlain>
              <ListItemPlain>Stabilize rating tree</ListItemPlain>
            </CollapsibleSection>
          </ListPlain>
        </Host>
      </View>
    </>
  );
}
  */

export default function Index() {
  return Workspaces();
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  host: {
    flex: 1,
  },
});
