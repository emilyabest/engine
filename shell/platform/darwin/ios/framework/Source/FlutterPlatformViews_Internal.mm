// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterPlatformViews_Internal.h"

#include "flutter/display_list/display_list_image_filter.h"
#include "flutter/fml/platform/darwin/cf_utils.h"
#import "flutter/shell/platform/darwin/ios/ios_surface.h"

static int kMaxPointsInVerb = 4;

namespace flutter {

FlutterPlatformViewLayer::FlutterPlatformViewLayer(
    fml::scoped_nsobject<UIView> overlay_view,
    fml::scoped_nsobject<UIView> overlay_view_wrapper,
    std::unique_ptr<IOSSurface> ios_surface,
    std::unique_ptr<Surface> surface)
    : overlay_view(std::move(overlay_view)),
      overlay_view_wrapper(std::move(overlay_view_wrapper)),
      ios_surface(std::move(ios_surface)),
      surface(std::move(surface)){};

FlutterPlatformViewLayer::~FlutterPlatformViewLayer() = default;

FlutterPlatformViewsController::FlutterPlatformViewsController()
    : layer_pool_(std::make_unique<FlutterPlatformViewLayerPool>()),
      weak_factory_(std::make_unique<fml::WeakPtrFactory<FlutterPlatformViewsController>>(this)){};

FlutterPlatformViewsController::~FlutterPlatformViewsController() = default;

fml::WeakPtr<flutter::FlutterPlatformViewsController> FlutterPlatformViewsController::GetWeakPtr() {
  return weak_factory_->GetWeakPtr();
}

CATransform3D GetCATransform3DFromSkMatrix(const SkMatrix& matrix) {
  // Skia only supports 2D transform so we don't map z.
  CATransform3D transform = CATransform3DIdentity;
  transform.m11 = matrix.getScaleX();
  transform.m21 = matrix.getSkewX();
  transform.m41 = matrix.getTranslateX();
  transform.m14 = matrix.getPerspX();

  transform.m12 = matrix.getSkewY();
  transform.m22 = matrix.getScaleY();
  transform.m42 = matrix.getTranslateY();
  transform.m24 = matrix.getPerspY();
  return transform;
}

void ResetAnchor(CALayer* layer) {
  // Flow uses (0, 0) to apply transform matrix so we need to match that in Quartz.
  layer.anchorPoint = CGPointZero;
  layer.position = CGPointZero;
}

}  // namespace flutter

@interface ChildClippingView()
// The gaussianFilters currently applied to this ChildClippingView.
@property(nonatomic, retain) NSMutableArray* activeGaussianFilters;
@end

@implementation ChildClippingView {
  // A gaussianFilter from UIVisualEffectView that can be copied for new backdrop filters.
  NSObject* _gaussianFilter;
}

// The ChildClippingView's frame is the bounding rect of the platform view. we only want touches to
// be hit tested and consumed by this view if they are inside the embedded platform view which could
// be smaller the embedded platform view is rotated.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
  for (UIView* view in self.subviews) {
    if ([view pointInside:[self convertPoint:point toView:view] withEvent:event]) {
      return YES;
    }
  }
  return NO;
}

// Creates and initializes a UIVisualEffectView with a UIBlurEffect. Extracts and returns its
// gaussianFilter. Logs errors and returns if Apple's API has changed and the filter can't be
// extracted.
+ (NSObject*)extractGaussianFilter { // TODO would pass by reference make more sense?
  UIVisualEffectView* visualEffectView = [[UIVisualEffectView alloc]
      initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleLight]];

  NSObject* gaussianFilter; //TODO EMILY: Weiyu's for loop works, but only if retain is included, why?
  for(CIFilter* filter in [visualEffectView.subviews firstObject].layer.filters) {
    if([[filter valueForKey:@"name"] isEqual:@"gaussianBlur"]) {
      gaussianFilter = filter;
      [gaussianFilter retain];
      break;
    }
  }

  if (!gaussianFilter) {
    FML_DLOG(ERROR) << "Apple's API for UIVisualEffectView changed. Update the implementation to "
                       "access the Gaussian blur filter. ";
    return nil;
  }

  [visualEffectView release];

  if (![[gaussianFilter valueForKey:@"inputRadius"] isKindOfClass:[NSNumber class]]) {
    FML_DLOG(ERROR) << "Apple's API for UIVisualEffectView changed. Update the implementation "
                       "access the Gaussian blur filter's properties.";
    [gaussianFilter release];
    return nil;
  }

//  [gaussianFilter release];
  return gaussianFilter;
}

// TODO EMILY: pass by reference works, but only if retain is still included
//- (void)extractGaussianFilter:(NSObject**)gaussianFilter {
//  UIVisualEffectView* visualEffectView = [[UIVisualEffectView alloc]
//      initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleLight]];
//
////  NSObject* gaussianFilter;
////  for(CIFilter* filter in [visualEffectView.subviews firstObject].layer.filters) {
////    if([[filter valueForKey:@"name"] isEqual:@"gaussianBlur"]) {
////      gaussianFilter = filter;
//////      [gaussianFilter retain];
////      break;
////    }
////  }
//
//  NSObject* extractedGaussianFilter =
//      [[visualEffectView.subviews firstObject].layer.filters firstObject]; // TODO why do we retain? -> make a note
//  if (!extractedGaussianFilter || ![[extractedGaussianFilter valueForKey:@"name"] isEqual:@"gaussianBlur"]) {
//    FML_DLOG(ERROR) << "Apple's API for UIVisualEffectView changed. Update the implementation to "
//                       "access the Gaussian blur filter. ";
//  }
//
//  [visualEffectView release];
//
//  if (![[extractedGaussianFilter valueForKey:@"inputRadius"] isKindOfClass:[NSNumber class]]) {
//    FML_DLOG(ERROR) << "Apple's API for UIVisualEffectView changed. Update the implementation "
//                       "access the Gaussian blur filter's properties.";
//  }
//
//  *gaussianFilter = extractedGaussianFilter;
//}

- (BOOL)applyBlurBackdropFilters:(NSArray*)blurRadii {
  if (!_activeGaussianFilters) {
    _activeGaussianFilters = [[[NSMutableArray alloc] init] retain];

//    [self extractGaussianFilter:&_gaussianFilter];
    _gaussianFilter = [ChildClippingView extractGaussianFilter];
    if (!_gaussianFilter) {
      return false;
    }
  }

  bool updatedFilters = false;

  // Update the size of _activeGaussianFilters to match the number of applied backdrop filters.
  while ([blurRadii count] > [_activeGaussianFilters count]) {
    // copy returns a deep copy of _gaussianFilter
    [_activeGaussianFilters addObject:[_gaussianFilter copy]];
    updatedFilters = true;
  }
  while ([blurRadii count] < [_activeGaussianFilters count]) {
    [_activeGaussianFilters removeLastObject];
    updatedFilters = true;
  }

  for (NSUInteger i = 0; i < [blurRadii count]; i++) {
    if ([_activeGaussianFilters[i] valueForKey:@"inputRadius"] == blurRadii[i]) {
      continue;
    }
    [_activeGaussianFilters[i] setValue:blurRadii[i] forKey:@"inputRadius"];
    updatedFilters = true;
  }

  if (updatedFilters) {
    self.layer.filters = _activeGaussianFilters;
  }
  return true;
}

- (void)dealloc {
  [_activeGaussianFilters release];
  _activeGaussianFilters = nil;

  [_gaussianFilter release];
  _gaussianFilter = nil;
  [super dealloc];
}

@end

@interface FlutterClippingMaskView ()

- (fml::CFRef<CGPathRef>)getTransformedPath:(CGPathRef)path matrix:(CATransform3D)matrix;
- (CGRect)getCGRectFromSkRect:(const SkRect&)clipSkRect;

@end

@implementation FlutterClippingMaskView {
  std::vector<fml::CFRef<CGPathRef>> paths_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    self.backgroundColor = UIColor.clearColor;
  }
  return self;
}

// In some scenarios, when we add this view as a maskView of the ChildClippingView, iOS added
// this view as a subview of the ChildClippingView.
// This results this view blocking touch events on the ChildClippingView.
// So we should always ignore any touch events sent to this view.
// See https://github.com/flutter/flutter/issues/66044
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
  return NO;
}

- (void)drawRect:(CGRect)rect {
  CGContextRef context = UIGraphicsGetCurrentContext();
  CGContextSaveGState(context);

  // For mask view, only the alpha channel is used.
  CGContextSetAlpha(context, 1);

  for (size_t i = 0; i < paths_.size(); i++) {
    CGContextAddPath(context, paths_.at(i));
    CGContextClip(context);
  }
  CGContextFillRect(context, rect);
  CGContextRestoreGState(context);
}

- (void)clipRect:(const SkRect&)clipSkRect matrix:(const CATransform3D&)matrix {
  CGRect clipRect = [self getCGRectFromSkRect:clipSkRect];
  CGPathRef path = CGPathCreateWithRect(clipRect, nil);
  paths_.push_back([self getTransformedPath:path matrix:matrix]);
}

- (void)clipRRect:(const SkRRect&)clipSkRRect matrix:(const CATransform3D&)matrix {
  CGPathRef pathRef = nullptr;
  switch (clipSkRRect.getType()) {
    case SkRRect::kEmpty_Type: {
      break;
    }
    case SkRRect::kRect_Type: {
      [self clipRect:clipSkRRect.rect() matrix:matrix];
      return;
    }
    case SkRRect::kOval_Type:
    case SkRRect::kSimple_Type: {
      CGRect clipRect = [self getCGRectFromSkRect:clipSkRRect.rect()];
      pathRef = CGPathCreateWithRoundedRect(clipRect, clipSkRRect.getSimpleRadii().x(),
                                            clipSkRRect.getSimpleRadii().y(), nil);
      break;
    }
    case SkRRect::kNinePatch_Type:
    case SkRRect::kComplex_Type: {
      CGMutablePathRef mutablePathRef = CGPathCreateMutable();
      // Complex types, we manually add each corner.
      SkRect clipSkRect = clipSkRRect.rect();
      SkVector topLeftRadii = clipSkRRect.radii(SkRRect::kUpperLeft_Corner);
      SkVector topRightRadii = clipSkRRect.radii(SkRRect::kUpperRight_Corner);
      SkVector bottomRightRadii = clipSkRRect.radii(SkRRect::kLowerRight_Corner);
      SkVector bottomLeftRadii = clipSkRRect.radii(SkRRect::kLowerLeft_Corner);

      // Start drawing RRect
      // Move point to the top left corner adding the top left radii's x.
      CGPathMoveToPoint(mutablePathRef, nil, clipSkRect.fLeft + topLeftRadii.x(), clipSkRect.fTop);
      // Move point horizontally right to the top right corner and add the top right curve.
      CGPathAddLineToPoint(mutablePathRef, nil, clipSkRect.fRight - topRightRadii.x(),
                           clipSkRect.fTop);
      CGPathAddCurveToPoint(mutablePathRef, nil, clipSkRect.fRight, clipSkRect.fTop,
                            clipSkRect.fRight, clipSkRect.fTop + topRightRadii.y(),
                            clipSkRect.fRight, clipSkRect.fTop + topRightRadii.y());
      // Move point vertically down to the bottom right corner and add the bottom right curve.
      CGPathAddLineToPoint(mutablePathRef, nil, clipSkRect.fRight,
                           clipSkRect.fBottom - bottomRightRadii.y());
      CGPathAddCurveToPoint(mutablePathRef, nil, clipSkRect.fRight, clipSkRect.fBottom,
                            clipSkRect.fRight - bottomRightRadii.x(), clipSkRect.fBottom,
                            clipSkRect.fRight - bottomRightRadii.x(), clipSkRect.fBottom);
      // Move point horizontally left to the bottom left corner and add the bottom left curve.
      CGPathAddLineToPoint(mutablePathRef, nil, clipSkRect.fLeft + bottomLeftRadii.x(),
                           clipSkRect.fBottom);
      CGPathAddCurveToPoint(mutablePathRef, nil, clipSkRect.fLeft, clipSkRect.fBottom,
                            clipSkRect.fLeft, clipSkRect.fBottom - bottomLeftRadii.y(),
                            clipSkRect.fLeft, clipSkRect.fBottom - bottomLeftRadii.y());
      // Move point vertically up to the top left corner and add the top left curve.
      CGPathAddLineToPoint(mutablePathRef, nil, clipSkRect.fLeft,
                           clipSkRect.fTop + topLeftRadii.y());
      CGPathAddCurveToPoint(mutablePathRef, nil, clipSkRect.fLeft, clipSkRect.fTop,
                            clipSkRect.fLeft + topLeftRadii.x(), clipSkRect.fTop,
                            clipSkRect.fLeft + topLeftRadii.x(), clipSkRect.fTop);
      CGPathCloseSubpath(mutablePathRef);

      pathRef = mutablePathRef;
      break;
    }
  }
  // TODO(cyanglaz): iOS does not seem to support hard edge on CAShapeLayer. It clearly stated that
  // the CAShaperLayer will be drawn antialiased. Need to figure out a way to do the hard edge
  // clipping on iOS.
  paths_.push_back([self getTransformedPath:pathRef matrix:matrix]);
}

- (void)clipPath:(const SkPath&)path matrix:(const CATransform3D&)matrix {
  if (!path.isValid()) {
    return;
  }
  if (path.isEmpty()) {
    return;
  }
  CGMutablePathRef pathRef = CGPathCreateMutable();

  // Loop through all verbs and translate them into CGPath
  SkPath::Iter iter(path, true);
  SkPoint pts[kMaxPointsInVerb];
  SkPath::Verb verb = iter.next(pts);
  SkPoint last_pt_from_last_verb;
  while (verb != SkPath::kDone_Verb) {
    if (verb == SkPath::kLine_Verb || verb == SkPath::kQuad_Verb || verb == SkPath::kConic_Verb ||
        verb == SkPath::kCubic_Verb) {
      FML_DCHECK(last_pt_from_last_verb == pts[0]);
    }
    switch (verb) {
      case SkPath::kMove_Verb: {
        CGPathMoveToPoint(pathRef, nil, pts[0].x(), pts[0].y());
        last_pt_from_last_verb = pts[0];
        break;
      }
      case SkPath::kLine_Verb: {
        CGPathAddLineToPoint(pathRef, nil, pts[1].x(), pts[1].y());
        last_pt_from_last_verb = pts[1];
        break;
      }
      case SkPath::kQuad_Verb: {
        CGPathAddQuadCurveToPoint(pathRef, nil, pts[1].x(), pts[1].y(), pts[2].x(), pts[2].y());
        last_pt_from_last_verb = pts[2];
        break;
      }
      case SkPath::kConic_Verb: {
        // Conic is not available in quartz, we use quad to approximate.
        // TODO(cyanglaz): Better approximate the conic path.
        // https://github.com/flutter/flutter/issues/35062
        CGPathAddQuadCurveToPoint(pathRef, nil, pts[1].x(), pts[1].y(), pts[2].x(), pts[2].y());
        last_pt_from_last_verb = pts[2];
        break;
      }
      case SkPath::kCubic_Verb: {
        CGPathAddCurveToPoint(pathRef, nil, pts[1].x(), pts[1].y(), pts[2].x(), pts[2].y(),
                              pts[3].x(), pts[3].y());
        last_pt_from_last_verb = pts[3];
        break;
      }
      case SkPath::kClose_Verb: {
        CGPathCloseSubpath(pathRef);
        break;
      }
      case SkPath::kDone_Verb: {
        break;
      }
    }
    verb = iter.next(pts);
  }
  paths_.push_back([self getTransformedPath:pathRef matrix:matrix]);
}

- (fml::CFRef<CGPathRef>)getTransformedPath:(CGPathRef)path matrix:(CATransform3D)matrix {
  CGAffineTransform affine =
      CGAffineTransformMake(matrix.m11, matrix.m12, matrix.m21, matrix.m22, matrix.m41, matrix.m42);
  CGPathRef transformedPath = CGPathCreateCopyByTransformingPath(path, &affine);
  CGPathRelease(path);
  return fml::CFRef<CGPathRef>(transformedPath);
}

- (CGRect)getCGRectFromSkRect:(const SkRect&)clipSkRect {
  return CGRectMake(clipSkRect.fLeft, clipSkRect.fTop, clipSkRect.fRight - clipSkRect.fLeft,
                    clipSkRect.fBottom - clipSkRect.fTop);
}

@end
