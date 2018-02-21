//------------------------------------------------------------------------------
//
// Copyright (c) Microsoft Corporation.
// All rights reserved.
//
// This code is licensed under the MIT License.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
//------------------------------------------------------------------------------

#import <SafariServices/SafariServices.h>

#import "MSALWebUI.h"
#import "UIApplication+MSALExtensions.h"
#import "MSALTelemetry.h"
#import "MSIDTelemetry+Internal.h"
#import "MSIDTelemetryUIEvent.h"
#import "MSIDTelemetryEventStrings.h"

static MSALWebUI *s_currentWebSession = nil;

@interface MSALWebUI () <SFSafariViewControllerDelegate>

@property (readwrite) NSURL* url;
@property (readwrite) SFSafariViewController* safariViewController;
@property (readwrite) MSALWebUICompletionBlock completionBlock;
@property (readwrite) id<MSALRequestContext> context;
@property (readwrite) NSString* telemetryRequestId;
@property (readwrite) MSIDTelemetryUIEvent* telemetryEvent;

@end

@implementation MSALWebUI

+ (void)startWebUIWithURL:(NSURL *)url
                  context:(id<MSALRequestContext>)context
          completionBlock:(MSALWebUICompletionBlock)completionBlock
{
    CHECK_ERROR_COMPLETION(url, context, MSALErrorInternal, @"Attempted to start WebUI with nil URL");
    
    MSALWebUI *webUI = [MSALWebUI new];
    webUI->_context = context;
    [webUI startWithURL:url completionBlock:completionBlock];
}

+ (MSALWebUI *)getAndClearCurrentWebSession
{
    MSALWebUI *webSession = nil;
    @synchronized ([MSALWebUI class])
    {
        webSession = s_currentWebSession;
        s_currentWebSession = nil;
    }
    
    return webSession;
}

+ (BOOL)cancelCurrentWebAuthSession
{
    MSALWebUI *webSession = [MSALWebUI getAndClearCurrentWebSession];
    if (!webSession)
    {
        return NO;
    }
    [webSession cancel];
    return YES;
}

- (BOOL)clearCurrentWebSession
{
    @synchronized ([MSALWebUI class])
    {
        if (s_currentWebSession != self)
        {
            // There's no error param because this isn't on a critical path. If we're seeing this error there is
            // a developer error somewhere in the code, but that won't necessarily prevent MSAL from otherwise
            // working.
            MSID_LOG_ERROR(_context, @"Trying to clear out someone else's session");
            return NO;
        }
        
        s_currentWebSession = nil;
        return YES;
    }
}

- (void)cancel
{
    [_telemetryEvent setIsCancelled:YES];
    [self completeSessionWithResponse:nil orError:CREATE_MSID_LOG_ERROR(_context, MSALErrorSessionCanceled, @"Authorization session was cancelled programatically")];
}

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller
{
    (void)controller;
    if (![self clearCurrentWebSession])
    {
        return;
    }
    
    [_telemetryEvent setIsCancelled:YES];
    [self completeSessionWithResponse:nil orError:CREATE_MSID_LOG_ERROR(_context, MSALErrorUserCanceled, @"User cancelled the authorization session.")];
}

- (void)startWithURL:(NSURL *)url
     completionBlock:(MSALWebUICompletionBlock)completionBlock
{
    @synchronized ([MSALWebUI class])
    {
        CHECK_ERROR_COMPLETION((!s_currentWebSession), _context, MSALErrorInteractiveSessionAlreadyRunning, @"Only one interactive session is allowed at a time.");
        s_currentWebSession = self;
    }
    
    _telemetryRequestId = [_context telemetryRequestId];
    
    [[MSIDTelemetry sharedInstance] startEvent:_telemetryRequestId eventName:MSID_TELEMETRY_EVENT_UI_EVENT];
    _telemetryEvent = [[MSIDTelemetryUIEvent alloc] initWithName:MSID_TELEMETRY_EVENT_UI_EVENT
                                                       context:_context];
    
    [_telemetryEvent setIsCancelled:NO];
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.safariViewController = [[SFSafariViewController alloc] initWithURL:url
                                  entersReaderIfAvailable:NO];
        weakSelf.safariViewController.delegate = self;
        UIViewController *viewController = [UIApplication msalCurrentViewController];
        if (!viewController)
        {
            [self clearCurrentWebSession];
            ERROR_COMPLETION(weakSelf.context, MSALErrorNoViewController, @"MSAL was unable to find the current view controller.");
        }
        
        [viewController presentViewController:weakSelf.safariViewController animated:YES completion:nil];
        
        @synchronized (weakSelf)
        {
            weakSelf.completionBlock = completionBlock;
        }
    });
}

+ (BOOL)handleResponse:(NSURL *)url
{
    if (!url)
    {
        MSID_LOG_ERROR(nil, @"nil passed into MSAL Web handle response");
        return NO;
    }
    
    MSALWebUI *webSession = [MSALWebUI getAndClearCurrentWebSession];
    if (!webSession)
    {
        MSID_LOG_ERROR(nil, @"Received MSAL web response without a current session running.");
        return NO;
    }
    
    return [webSession completeSessionWithResponse:url orError:nil];
}

- (BOOL)completeSessionWithResponse:(NSURL *)response
                            orError:(NSError *)error
{
    __weak typeof(self) weakSelf = self;
    if ([NSThread isMainThread])
    {
        [weakSelf.safariViewController dismissViewControllerAnimated:YES completion:nil];
    }
    else
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.safariViewController dismissViewControllerAnimated:YES completion:nil];
        });
    }
    
    MSALWebUICompletionBlock completionBlock = nil;
    @synchronized (self)
    {
        completionBlock = weakSelf.completionBlock;
        weakSelf.completionBlock = nil;
    }
    
    self.safariViewController = nil;
    
    if (!completionBlock)
    {
        MSID_LOG_ERROR(self.context, @"MSAL response received but no completion block saved");
        return NO;
    }
    
    [[MSIDTelemetry sharedInstance] stopEvent:self.telemetryRequestId event:self.telemetryEvent];
    
    completionBlock(response, error);
    return YES;
}

@end
