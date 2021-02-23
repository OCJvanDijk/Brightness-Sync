//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import <CoreGraphics/CoreGraphics.h>

double CoreDisplay_Display_GetUserBrightness(CGDirectDisplayID display);
double CoreDisplay_Display_GetDynamicLinearBrightness(CGDirectDisplayID display);
double CoreDisplay_Display_GetLinearBrightness(CGDirectDisplayID display);
void CoreDisplay_Display_SetUserBrightness(CGDirectDisplayID display, double brightness);
void CoreDisplay_Display_SetDynamicLinearBrightness(CGDirectDisplayID display, double brightness);
void CoreDisplay_Display_SetLinearBrightness(CGDirectDisplayID display, double brightness);

CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID);

int DisplayServicesGetLinearBrightness(CGDirectDisplayID display, float *brightness);
int DisplayServicesSetLinearBrightness(CGDirectDisplayID display, float brightness);
