const path = require('path');
const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');

// Thư viện nằm ở thư mục cha (`file:..`): theo dõi thư mục đó và chỉ lấy node_modules của app mẫu.
const root = path.resolve(__dirname, '..');

/** @type {import('@react-native/metro-config').MetroConfig} */
const config = {
  watchFolders: [root],
  resolver: {
    nodeModulesPaths: [path.resolve(__dirname, 'node_modules')],
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
