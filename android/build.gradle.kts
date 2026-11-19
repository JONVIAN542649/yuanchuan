allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.set(newBuildDir)
subprojects {
    layout.buildDirectory.set(newBuildDir.dir(project.name))
}

// Some published Flutter plugins still hard-code an older compileSdk. The app
// targets API 36, so align every Android library module before AGP finalizes it.
subprojects {
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library")) {
            val android = extensions.findByName("android")
            if (android != null) {
                val setCompileSdk = android.javaClass.methods.firstOrNull { method ->
                    method.name == "setCompileSdk" &&
                        method.parameterCount == 1 &&
                        (method.parameterTypes[0] == Int::class.javaObjectType ||
                            method.parameterTypes[0] == Int::class.javaPrimitiveType)
                }
                setCompileSdk?.invoke(android, 36)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
