/*
 * Copyright (C) 2019 HERE Europe B.V.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 * License-Filename: LICENSE
 */

#import "OLPHttpClient+Internal.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

#include "olp/core/logging/Log.h"
#include "olp/core/http/Network.h"
#include "olp/core/http/NetworkProxySettings.h"

#import "OLPHttpTask+Internal.h"

namespace {
constexpr auto kLogTag = "OLPHttpClient";
}  // namespace

@interface OLPHttpClient ()<NSURLSessionDataDelegate>

@property(nonatomic) NSMutableDictionary* tasks;

@property(nonatomic) NSMutableDictionary* urlSessions;

@property(nonatomic, readonly) NSURLSession* sharedUrlSession;

@property(nonatomic, readonly) NSMutableDictionary* idTaskMap;

@end

@implementation OLPHttpClient {
  NSOperationQueue* _delegateQueue;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    OLP_SDK_LOG_TRACE_F(kLogTag, "Created client=%p ", (__bridge void*)self);
    _delegateQueue = [[NSOperationQueue alloc] init];
    _delegateQueue.name = @"com.here.olp.network.HttpClientSessionQueue";

    _sharedUrlSession =
        [self urlSessionWithProxy:olp::http::NetworkProxySettings()
                       andHeaders:nil];

    _tasks = [[NSMutableDictionary alloc] init];
    _idTaskMap = [[NSMutableDictionary alloc] init];
    _urlSessions = [[NSMutableDictionary alloc] init];
  }
  return self;
}

- (void)dealloc {
  OLP_SDK_LOG_TRACE_F(kLogTag, "Destroyed client=%p ", (__bridge void*)self);
  if (self.sharedUrlSession) {
    [self cleanup];
  }
}

- (void)cleanup {
  OLP_SDK_LOG_TRACE_F(kLogTag, "Cleanup tasks for client=%p",
                      (__bridge void*)self);

  [self.sharedUrlSession finishTasksAndInvalidate];
  [self.urlSessions
      enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL* stop) {
        NSURLSession* session = object;
        [session finishTasksAndInvalidate];
      }];
  [_delegateQueue cancelAllOperations];
  _sharedUrlSession = nil;
  [self.urlSessions removeAllObjects];
}

- (NSArray*)activeTasks {
  NSArray* tasks = nil;
  @synchronized(_tasks) {
    tasks = [NSArray arrayWithArray:_tasks.allValues];
  }
  return tasks;
}

- (OLPHttpTask*)createTaskWithProxy:
                    (const olp::http::NetworkProxySettings&)proxySettings
                              andId:(olp::http::RequestId)identifier {
  NSURLSession* session = _sharedUrlSession;
  BOOL isProxyValid =
      proxySettings.GetType() != olp::http::NetworkProxySettings::Type::NONE &&
      !proxySettings.GetHostname().empty();
  if (isProxyValid) {
    session = [self urlSessionWithProxy:proxySettings andHeaders:nil];
  }

  OLPHttpTask* task = [[OLPHttpTask alloc] initWithHttpClient:self
                                                andURLSession:session
                                                        andId:identifier];

  @synchronized(self.tasks) {
    self.urlSessions[@(identifier)] = session;
    self.tasks[@(identifier)] = task;
  }

  return task;
}

- (OLPHttpTask*)taskWithId:(olp::http::RequestId)identifier {
  OLPHttpTask* task;
  @synchronized(_tasks) {
    task = _tasks[@(identifier)];
  }
  return task;
}

- (OLPHttpTask*)taskWithTaskIdentifier:(NSUInteger)taskId {
  OLPHttpTask* task = nil;
  @synchronized(_tasks) {
    task = self.idTaskMap[@(taskId)];
  }
  return task;
}

- (void)cancelTaskWithId:(olp::http::RequestId)identifier {
  OLPHttpTask* task = nil;
  @synchronized(_tasks) {
    task = _tasks[@(identifier)];
  }
  if (!task) {
    OLP_SDK_LOG_WARNING_F(kLogTag, "Cancelling unknown request, id=%llu",
                          identifier);
    return;
  }

  [task cancel];
}

- (void)removeTaskWithId:(olp::http::RequestId)identifier {
  @synchronized(_tasks) {
    OLPHttpTask* task = _tasks[@(identifier)];
    if (task.dataTask) {
      [task.dataTask cancel];
      [self.idTaskMap removeObjectForKey:@(task.dataTask.taskIdentifier)];
    }
    [_tasks removeObjectForKey:@(identifier)];
    [self.urlSessions removeObjectForKey:@(identifier)];
  }
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession*)session
                    task:(NSURLSessionTask*)task
    didCompleteWithError:(NSError*)error {
  if (!self.sharedUrlSession &&
      NSURLErrorCancelled != error.code) {  // Cleanup called and not cancelled
    OLP_SDK_LOG_WARNING_F(kLogTag,
                          "didCompleteWithError failed, "
                          "task_id=%u; error=%i",
                          (unsigned int)task.taskIdentifier, (int)error.code);
    return;
  }

  @autoreleasepool {
    OLPHttpTask* httpTask = [self taskWithTaskIdentifier:task.taskIdentifier];
    if ([httpTask isValid]) {
      [httpTask didCompleteWithError:error];
      [self removeTaskWithId:httpTask.requestId];
    } else {
      OLP_SDK_LOG_WARNING_F(
          kLogTag,
          "didCompleteWithError failed - can't find the task, "
          "task_id=%u, error=%i",
          (unsigned int)task.taskIdentifier, (int)error.code);
    }
  }
}

- (void)URLSession:(NSURLSession*)session
              dataTask:(NSURLSessionDataTask*)dataTask
    didReceiveResponse:(NSURLResponse*)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))
                           completionHandler {
  if (!self.sharedUrlSession) {  // Cleanup called
    OLP_SDK_LOG_WARNING_F(kLogTag,
                          "didReceiveResponse failed - invalid session, "
                          "task_id=%u, url=%s, status_code=%i",
                          (unsigned int)dataTask.taskIdentifier,
                          [response.URL.absoluteString UTF8String],
                          (int)[(NSHTTPURLResponse*)response statusCode]);
    return;
  }

  @autoreleasepool {
    OLPHttpTask* httpTask =
        [self taskWithTaskIdentifier:dataTask.taskIdentifier];
    if ([httpTask isValid] && ![httpTask isCancelled]) {
      [httpTask didReceiveResponse:response];
    } else {
      OLP_SDK_LOG_WARNING_F(
          kLogTag,
          "didReceiveResponse failed - task can't be found or cancelled, "
          "task_id=%u, url=%s, status=%i",
          (unsigned int)dataTask.taskIdentifier,
          [response.URL.absoluteString UTF8String],
          (int)[(NSHTTPURLResponse*)response statusCode]);
    }
    completionHandler(NSURLSessionResponseAllow);
  }
}

- (void)URLSession:(NSURLSession*)session
          dataTask:(NSURLSessionDataTask*)dataTask
    didReceiveData:(NSData*)data {
  if (!self.sharedUrlSession) {  // Cleanup called
    OLP_SDK_LOG_WARNING_F(kLogTag,
                          "didReceiveData failed - invalid session, "
                          "task_id=%u",
                          (unsigned int)dataTask.taskIdentifier);
    return;
  }

  @autoreleasepool {
    OLPHttpTask* httpTask =
        [self taskWithTaskIdentifier:dataTask.taskIdentifier];
    if ([httpTask isValid] && ![httpTask isCancelled]) {
      [httpTask didReceiveData:data];
    } else {
      OLP_SDK_LOG_WARNING_F(
          kLogTag,
          "didReceiveData failed - task can't be found or cancelled, "
          "task_id=%u",
          (unsigned int)dataTask.taskIdentifier);
    }
  }
}

- (void)URLSession:(NSURLSession*)session
                   task:(NSURLSessionTask*)dataTask
    didReceiveChallenge:(NSURLAuthenticationChallenge*)challenge
      completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition,
                                  NSURLCredential*))completionHandler {
  if (!self.sharedUrlSession) {  // Cleanup called
    OLP_SDK_LOG_WARNING_F(kLogTag,
                          "didReceiveChallenge failed - invalid session, "
                          "task_id=%u",
                          (unsigned int)dataTask.taskIdentifier);
    return;
  }

  @autoreleasepool {
    if ([challenge.protectionSpace.authenticationMethod
            isEqualToString:NSURLAuthenticationMethodServerTrust]) {
      if (dataTask) {
        OLPHttpTask* httpTask =
            [self taskWithTaskIdentifier:dataTask.taskIdentifier];
        if (![httpTask isValid]) {
          return;
        }
        // TODO: Don't verify certificate is not implemented
        if (![self shouldTrustProtectionSpace:challenge.protectionSpace]) {
          completionHandler(
              NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
          return;
        }
      }

      NSURLCredential* credential = [NSURLCredential
          credentialForTrust:challenge.protectionSpace.serverTrust];
      completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
      return;
    }

    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
  }
}

- (void)URLSession:(NSURLSession*)session
                          task:(NSURLSessionTask*)task
    willPerformHTTPRedirection:(NSHTTPURLResponse*)response
                    newRequest:(NSURLRequest*)request
             completionHandler:
                 (void (^)(NSURLRequest* _Nullable))completionHandler {
  if (!self.sharedUrlSession) {  // Cleanup called
    OLP_SDK_LOG_WARNING_F(
        kLogTag,
        "willPerformHTTPRedirection failed - invalid session, "
        "task_id=%u, status=%i, origin_url=%s, new_url=%s",
        (unsigned int)task.taskIdentifier, (int)response.statusCode,
        task.originalRequest.URL.absoluteString.UTF8String,
        request.URL.absoluteString.UTF8String);
    return;
  }

  NSURLRequest* originalRequest = task.originalRequest;
  NSString* authorizationHeaderValue =
      originalRequest.allHTTPHeaderFields[@"Authorization"];
  OLP_SDK_LOG_TRACE_F(kLogTag,
                      "HTTPRedirection: self=%p, task_id=%u, "
                      "status=%i, origin_url=%s, new_url=%s",
                      (__bridge void*)self, (unsigned int)task.taskIdentifier,
                      (int)response.statusCode,
                      originalRequest.URL.absoluteString.UTF8String,
                      request.URL.absoluteString.UTF8String);
  NSMutableURLRequest* newRequest = [[NSMutableURLRequest alloc] init];
  newRequest.URL = request.URL;
  newRequest.timeoutInterval = request.timeoutInterval;
  newRequest.cachePolicy = request.cachePolicy;
  newRequest.networkServiceType = request.networkServiceType;
  newRequest.HTTPMethod = request.HTTPMethod;
  newRequest.HTTPBody = request.HTTPBody;
  [request.allHTTPHeaderFields
      enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL* stop) {
        [newRequest addValue:object forHTTPHeaderField:key];
      }];

  // NOTE: It appears that most headers are maintained during a redirect with
  // the exception of the `Authorization` header.
  // It appears that Apple's strips the `Authorization` header from the
  // redirected URL request. If you need to maintain the `Authorization` header,
  // you need to manually append it to the redirected request.
  if (authorizationHeaderValue.length) {
    [newRequest addValue:authorizationHeaderValue
        forHTTPHeaderField:@"Authorization"];
  }
  completionHandler(newRequest);
}

// http://goo.gl/jmZ4Uv
- (BOOL)shouldTrustProtectionSpace:(NSURLProtectionSpace*)protectionSpace {
  if (!protectionSpace) {
    return NO;
  }

  SecTrustRef serverTrust = protectionSpace.serverTrust;
  if (!serverTrust) {
    return NO;
  }

  // TODO - certificate paths are not supported!

  // evaluate server trust against certificate
  SecTrustResultType trustResult = kSecTrustResultInvalid;
  OSStatus status = SecTrustEvaluate(serverTrust, &trustResult);

  if (errSecSuccess != status) {
    return NO;
  }

  return (trustResult == kSecTrustResultUnspecified ||
          trustResult == kSecTrustResultProceed);
}

#pragma mark - Internal methods

- (NSURLSession*)urlSessionWithProxy:
                     (const olp::http::NetworkProxySettings&)proxySettings
                          andHeaders:(NSDictionary*)headers {
  NSMutableDictionary* proxyDict = nil;
  BOOL isProxyValid =
      proxySettings.GetType() != olp::http::NetworkProxySettings::Type::NONE &&
      !proxySettings.GetHostname().empty();

  if (isProxyValid) {
    NSString* proxyName =
        [NSString stringWithUTF8String:proxySettings.GetHostname().c_str()];
    if (proxyName.length) {
      proxyDict = [[NSMutableDictionary alloc] init];
      NSUInteger port = (NSUInteger)proxySettings.GetPort();

      const auto requestedProxyType = proxySettings.GetType();

      using ProxyType = olp::http::NetworkProxySettings::Type;

      if (ProxyType::SOCKS4 == requestedProxyType ||
          ProxyType::SOCKS5 == requestedProxyType ||
          ProxyType::SOCKS5_HOSTNAME == requestedProxyType) {
          proxyDict[(__bridge NSString*)kCFProxyTypeKey] = (__bridge NSString*)kCFProxyTypeSOCKS;
      } else if (ProxyType::HTTP == requestedProxyType) {
          proxyDict[(__bridge NSString*)kCFNetworkProxiesHTTPEnable] = @(1);
          proxyDict[(__bridge NSString*)kCFNetworkProxiesHTTPProxy] = proxyName;
          proxyDict[(__bridge NSString*)kCFNetworkProxiesHTTPPort] = @(port);
      } else if (ProxyType::HTTPS == requestedProxyType) {
          proxyDict[@"HTTPSEnable"] = @(1);
          proxyDict[@"HTTPSProxy"] = proxyName;
          proxyDict[@"HTTPSPort"] = @(port);
      }

      proxyDict[(__bridge NSString*)kCFProxyHostNameKey] = proxyName;
      proxyDict[(__bridge NSString*)kCFProxyPortNumberKey] = @(port);
      NSString* userName =
          [NSString stringWithUTF8String:proxySettings.GetUsername().c_str()];
      NSString* userPassword =
          [NSString stringWithUTF8String:proxySettings.GetPassword().c_str()];
      if (userName.length && userPassword.length) {
        proxyDict[(NSString*)kCFProxyUsernameKey] = userName;
        proxyDict[(NSString*)kCFProxyPasswordKey] = userPassword;
      }
    }
  }

  NSURLSessionConfiguration* config =
      [NSURLSessionConfiguration ephemeralSessionConfiguration];
  if (proxyDict) {
    config.connectionProxyDictionary = proxyDict;
  }
  if (headers.count) {
    config.HTTPAdditionalHeaders = headers;
  }

  return [NSURLSession sessionWithConfiguration:config
                                       delegate:self
                                  delegateQueue:_delegateQueue];
}

- (void)registerDataTask:(NSURLSessionDataTask*)dataTask
             forHttpTask:(OLPHttpTask*)httpTask {
  NSNumber* identifier = @(dataTask.taskIdentifier);
  @synchronized(_tasks) {
    self.idTaskMap[identifier] = httpTask;
  }
}

@end
