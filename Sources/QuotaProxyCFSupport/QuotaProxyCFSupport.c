#include "QuotaProxyCFSupport.h"

#include <CFNetwork/CFNetwork.h>

typedef struct {
    CFArrayRef proxies;
    Boolean completed;
} QuotaPACResolution;

static void QuotaPACResolutionCallback(void *client, CFArrayRef proxyList, CFErrorRef error) {
    QuotaPACResolution *resolution = (QuotaPACResolution *)client;
    if (error == NULL && proxyList != NULL) {
        resolution->proxies = CFRetain(proxyList);
    }
    resolution->completed = true;
}

CFArrayRef QuotaCopyProxiesForAutoConfigurationURL(
    CFURLRef pacURL,
    CFURLRef targetURL,
    CFTimeInterval timeout
) {
    QuotaPACResolution resolution = {
        .proxies = NULL,
        .completed = false
    };

    CFStreamClientContext context = {
        .version = 0,
        .info = &resolution,
        .retain = NULL,
        .release = NULL,
        .copyDescription = NULL
    };

    CFRunLoopSourceRef source = CFNetworkExecuteProxyAutoConfigurationURL(
        pacURL,
        targetURL,
        QuotaPACResolutionCallback,
        &context
    );
    if (source == NULL) {
        return NULL;
    }

    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(runLoop, source, kCFRunLoopDefaultMode);

    const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    while (!resolution.completed && CFAbsoluteTimeGetCurrent() < deadline) {
        CFTimeInterval remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0) {
            break;
        }
        if (remaining > 0.05) {
            remaining = 0.05;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, remaining, false);
    }

    CFRunLoopRemoveSource(runLoop, source, kCFRunLoopDefaultMode);
    CFRunLoopSourceInvalidate(source);
    CFRelease(source);

    if (!resolution.completed) {
        if (resolution.proxies != NULL) {
            CFRelease(resolution.proxies);
        }
        return NULL;
    }

    return resolution.proxies;
}
