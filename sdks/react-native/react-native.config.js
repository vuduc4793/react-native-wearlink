// Autolinking: chỉ rõ package Android (Kotlin) của thư viện.
module.exports = {
  dependency: {
    platforms: {
      android: {
        packageImportPath: 'import com.smartwear.rn.SmartWearPackage;',
        packageInstance: 'new SmartWearPackage()',
      },
    },
  },
};
