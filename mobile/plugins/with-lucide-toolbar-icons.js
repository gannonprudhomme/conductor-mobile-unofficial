const fs = require("fs");
const path = require("path");

const { withDangerousMod } = require("@expo/config-plugins");

const icons = [
  "lucide_plus",
  "lucide_ellipsis",
  "lucide_settings",
  "lucide_git_pull_request",
];

module.exports = function withLucideToolbarIcons(config) {
  return withDangerousMod(config, [
    "ios",
    async (config) => {
      const { platformProjectRoot, projectName, projectRoot } = config.modRequest;
      const assetsRoot = path.join(projectRoot, "src/assets/toolbar-icons");
      const catalogRoot = path.join(
        platformProjectRoot,
        projectName,
        "Images.xcassets",
      );

      for (const icon of icons) {
        const imageSetRoot = path.join(catalogRoot, `${icon}.imageset`);
        fs.mkdirSync(imageSetRoot, { recursive: true });
        fs.copyFileSync(
          path.join(assetsRoot, `${icon}.svg`),
          path.join(imageSetRoot, `${icon}.svg`),
        );
        fs.writeFileSync(
          path.join(imageSetRoot, "Contents.json"),
          JSON.stringify(
            {
              images: [
                {
                  filename: `${icon}.svg`,
                  idiom: "universal",
                },
              ],
              info: {
                author: "expo",
                version: 1,
              },
              properties: {
                "preserves-vector-representation": true,
                "template-rendering-intent": "template",
              },
            },
            null,
            2,
          ) + "\n",
        );
      }

      return config;
    },
  ]);
};
