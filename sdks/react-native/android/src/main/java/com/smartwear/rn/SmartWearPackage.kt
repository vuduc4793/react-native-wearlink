package com.smartwear.rn

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

class SmartWearPackage : BaseReactPackage() {
    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
        if (name == SmartWearModule.NAME) SmartWearModule(reactContext) else null

    override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
        mapOf(
            SmartWearModule.NAME to ReactModuleInfo(
                SmartWearModule.NAME, SmartWearModule::class.java.name,
                false, // canOverrideExistingModule
                false, // needsEagerInit
                false, // isCxxModule
                true, // isTurboModule
            ),
        )
    }
}
