Placeholder for AdMob banner integration (library screen only, no
interstitials on song tap) and `in_app_purchase` wiring for "Remove Ads"
/ premium theme unlock. Not yet implemented.

STATUS: stripped for the pure offline MVP release. `google_mobile_ads`
and `in_app_purchase` are removed from pubspec.yaml, and the INTERNET /
com.android.vending.BILLING permissions plus the AdMob APPLICATION_ID
meta-data are removed from AndroidManifest.xml. To reintroduce in a
future connected release: re-add both dependencies, restore the two
permissions and the AdMob meta-data, and implement this module.
