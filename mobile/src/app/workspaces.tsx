import { ListItemPlain } from "@/components/ListItemPlain.ios";
import { ListPlain } from "@/components/ListPlain.ios";
import { Host, List } from "@expo/ui";
import { Stack } from "expo-router";
import { StyleSheet, View } from "react-native";

// The list of workspaces (the left sidebar)



function WorkspaceRow() {

}

export default function Workspaces() {
  return (
    <>
      <Stack.Toolbar placement="right">

      </Stack.Toolbar>

      <View style={styles.container}>
        <Host style={styles.host}>
          <ListPlain>
            <ListItemPlain>
              Text
            </ListItemPlain>
          </ListPlain>
        </Host>
      </View>
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  host: {
    flex: 1,
  },
});

