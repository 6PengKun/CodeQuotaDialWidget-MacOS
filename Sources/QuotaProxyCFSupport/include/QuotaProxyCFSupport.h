#ifndef QUOTA_PROXY_CF_SUPPORT_H
#define QUOTA_PROXY_CF_SUPPORT_H

#include <CoreFoundation/CoreFoundation.h>

CF_ASSUME_NONNULL_BEGIN

CFArrayRef _Nullable QuotaCopyProxiesForAutoConfigurationURL(
    CFURLRef pacURL,
    CFURLRef targetURL,
    CFTimeInterval timeout
) CF_RETURNS_RETAINED;

CF_ASSUME_NONNULL_END

#endif
