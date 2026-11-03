//
//  KayokoScriptResources.m
//  Kayoko
//

#import "KayokoScriptResources.h"

#import <roothide.h>

NSBundle *KayokoScriptResourcesBundle(void) {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      bundle = [NSBundle bundleWithPath:jbroot(@"/Library/PreferenceBundles/KayokoPreferences.bundle")];
      if (!bundle) {
          bundle = [NSBundle mainBundle];
      }
    });
    return bundle;
}

NSString *KayokoScriptLocalizedString(NSString *key, NSString *fallback) {
    NSString *localized = [KayokoScriptResourcesBundle() localizedStringForKey:key value:fallback table:@"Tweak"];
    return [localized length] > 0 ? localized : fallback;
}
