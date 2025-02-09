#!/bin/sh

install_apk=false
run_apk=false
sign_apk=false
sign_bundle=false
build_release=true

while getopts "sirqbh" OPT
do
	case $OPT in
		s) sign_apk=true;;
		i) install_apk=true;;
		r) install_apk=true ; run_apk=true;;
		q) echo "Quick rebuild does not work anymore with Gradle!";;
		b) sign_bundle=true;;
		h)
			echo "Usage: $0 [-s] [-i] [-r] [-q] [debug|release] [app-name]"
			echo "    -s:       sign .apk file after building"
			echo "    -b:       sign .aab app bundle file after building"
			echo "    -i:       install APK file to device after building"
			echo "    -r:       run APK file on device after building"
			echo "    debug:    build debug package"
			echo "    release:  build release package (default)"
			echo "    app-name: directory under project/jni/application to be compiled"
			exit 0
			;;
	esac
done
shift `expr $OPTIND - 1`

if [ "$#" -gt 0 -a "$1" = "release" ]; then
	shift
	build_release=true
fi

if [ "$#" -gt 0 -a "$1" = "debug" ]; then
	shift
	build_release=false
	export NDK_DEBUG=1
fi

if [ "$#" -gt 0 -a "$1" '!=' "-h" ]; then
	echo "Switching build target to $1"
	if [ -e project/jni/application/$1 ]; then
		rm -f project/jni/application/src
		ln -s "$1" project/jni/application/src
	else
		echo "Error: no app $1 under project/jni/application"
		echo "Available applications:"
		cd project/jni/application
		for f in *; do
			if [ -e "$f/AndroidAppSettings.cfg" ]; then
				echo "$f"
			fi
		done
		exit 1
	fi
	shift
fi

if [ -e project/local.properties ] && \
	grep "package `grep AppFullName= AndroidAppSettings.cfg | sed 's/.*=//'`;" project/src/Globals.java > /dev/null 2>&1 && \
	[ "`readlink AndroidAppSettings.cfg`" -ot "project/src/Globals.java" ] && \
	[ -z "`find project/java/* project/javaSDL2/* project/jni/sdl2/android-project/app/src/main/java/org/libsdl/app/* project/AndroidManifestTemplate.xml -cnewer project/src/Globals.java`" ]
then
	true
else
	./changeAppSettings.sh -a || exit 1
	sleep 1
	touch project/src/Globals.java
fi

MYARCH=linux-x86_64
if [ -z "$NCPU" ]; then
	NCPU=8
	if uname -s | grep -i "linux" > /dev/null ; then
		MYARCH=linux-x86_64
		NCPU=`cat /proc/cpuinfo | grep -c -i processor`
	fi
	if uname -s | grep -i "darwin" > /dev/null ; then
		MYARCH=darwin-x86_64
	fi
	if uname -s | grep -i "windows" > /dev/null ; then
		MYARCH=windows-x86_64
	fi
fi
export BUILD_NUM_CPUS=$NCPU

# Fix Gradle compilation error
[ -z "$ANDROID_NDK_HOME" ] && export ANDROID_NDK_HOME="`which ndk-build | sed 's@/ndk-build@@'`"

[ -x project/jni/application/src/AndroidPreBuild.sh ] && {
	cd project/jni/application/src
	./AndroidPreBuild.sh || { echo "AndroidPreBuild.sh returned with error" ; exit 1 ; }
	cd ../../../..
}

[ -n "`grep CustomBuildScript=y AndroidAppSettings.cfg`" ] && {
	ndk-build -C project -j$NCPU V=1 CUSTOM_BUILD_SCRIPT_FIRST_PASS=1 NDK_APP_STRIP_MODE=none || exit 1
	make -C project/jni/application -f CustomBuildScript.mk || exit 1
}

ndk-build -C project -j$NCPU V=1 NDK_APP_STRIP_MODE=none && \
	./copyAssets.sh && cd project && \
	{	if $build_release ; then \
			./gradlew assembleRelease || exit 1 ; \
			[ '!' -x jni/application/src/AndroidPostBuild.sh ] || {
				cd jni/application/src ; \
				./AndroidPostBuild.sh `pwd`/../../../app/build/outputs/apk/release/app-release-unsigned.apk || exit 1 ; \
				cd ../../.. ; \
			} || exit 1 ; \
			../copyAssets.sh pack-binaries app/build/outputs/apk/release/app-release-unsigned.apk ; \
			rm -f app/build/outputs/apk/release/app-release.apk ; \
			zipalign -p 4 app/build/outputs/apk/release/app-release-unsigned.apk app/build/outputs/apk/release/app-release.apk ; \
			apksigner sign --ks ~/.android/debug.keystore --ks-key-alias androiddebugkey --ks-pass pass:android app/build/outputs/apk/release/app-release.apk || exit 1 ; \
		else \
			./gradlew assembleDebug || exit 1 ; \
			[ '!' -x jni/application/src/AndroidPostBuild.sh ] || {
				cd jni/application/src ; \
				./AndroidPostBuild.sh `pwd`/../../../app/build/outputs/apk/debug/app-debug.apk || exit 1 ; \
				cd ../../.. ; \
			} || exit 1 ; \
			mkdir -p app/build/outputs/apk/release ; \
			../copyAssets.sh pack-binaries app/build/outputs/apk/debug/app-debug.apk ; \
			rm -f app/build/outputs/apk/release/app-release.apk ; \
			zipalign -p 4 app/build/outputs/apk/debug/app-debug.apk app/build/outputs/apk/release/app-release.apk ; \
			apksigner sign --ks ~/.android/debug.keystore --ks-key-alias androiddebugkey --ks-pass pass:android app/build/outputs/apk/release/app-release.apk || exit 1 ; \
		fi ; } && \
	{	if $sign_apk; then cd .. && ./sign.sh && cd project ; else true ; fi ; } && \
	{	if $sign_bundle; then cd .. && ./signBundle.sh && cd project ; else true ; fi ; } && \
	{	$install_apk && [ -n "`adb devices | tail -n +2`" ] && \
		{	if $sign_apk; then \
				APPNAME=`grep AppName ../AndroidAppSettings.cfg | sed 's/.*=//' | tr -d '"' | tr " '/" '---'` ; \
				APPVER=`grep AppVersionName ../AndroidAppSettings.cfg | sed 's/.*=//' | tr -d '"' | tr " '/" '---'` ; \
				adb install -r ../$APPNAME-$APPVER.apk ; \
			else \
				adb install -r app/build/outputs/apk/release/app-release.apk ; \
			fi ; } ; \
		true ; } && \
	{	$run_apk && { \
			ActivityName="`grep AppFullName ../AndroidAppSettings.cfg | sed 's/.*=//'`/.MainActivity" ; \
			RUN_APK="adb shell am start -n $ActivityName" ; \
			echo "Running $ActivityName on the USB-connected device:" ; \
			echo "$RUN_APK" ; \
			eval $RUN_APK ; } ; \
		true ; } || exit 1
