import { Text, View, StyleSheet } from "react-native";
import { Host, List, ListItem, Row} from "@expo/ui";

export default function Index() {
  return (
    // <View style={styles.container}>
    //   <Text>Edit src/app/index.tsx to edit this screen.</Text>
    // </View>
    <View style={styles.container}>
      <Host>
        <List>
          <ListItem>
            <Row spacing={8}>
              <Text> SOmething </Text>
            </Row>
          </ListItem>
        </List>
      </Host>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
  },
});
