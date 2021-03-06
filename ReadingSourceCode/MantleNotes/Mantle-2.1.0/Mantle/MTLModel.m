//
//  MTLModel.m
//  Mantle
//
//  Created by Justin Spahr-Summers on 2012-09-11.
//  Copyright (c) 2012 GitHub. All rights reserved.
//

#import "NSError+MTLModelException.h"
#import "MTLModel.h"
#import "EXTRuntimeExtensions.h"
#import "EXTScope.h"
#import "MTLReflection.h"
#import <objc/runtime.h>

// Used to cache the reflection performed in +propertyKeys.
static void *MTLModelCachedPropertyKeysKey = &MTLModelCachedPropertyKeysKey;

// Associated in +generateAndCachePropertyKeys with a set of all transitory
// property keys.
static void *MTLModelCachedTransitoryPropertyKeysKey = &MTLModelCachedTransitoryPropertyKeysKey;

// Associated in +generateAndCachePropertyKeys with a set of all permanent
// property keys.
static void *MTLModelCachedPermanentPropertyKeysKey = &MTLModelCachedPermanentPropertyKeysKey;

// Validates a value for an object and sets it if necessary.
//
// obj         - The object for which the value is being validated. This value
//               must not be nil.
// key         - The name of one of `obj`s properties. This value must not be
//               nil.
// value       - The new value for the property identified by `key`.
// forceUpdate - If set to `YES`, the value is being updated even if validating
//               it did not change it.
// error       - If not NULL, this may be set to any error that occurs during
//               validation
//
// Returns YES if `value` could be validated and set, or NO if an error
// occurred.
static BOOL MTLValidateAndSetValue(id obj, NSString *key, id value, BOOL forceUpdate, NSError **error) {
	// Mark this as being autoreleased, because validateValue may return
	// a new object to be stored in this variable (and we don't want ARC to
	// double-free or leak the old or new values).
	__autoreleasing id validatedValue = value;

	@try {
		if (![obj validateValue:&validatedValue forKey:key error:error]) return NO;

		if (forceUpdate || value != validatedValue) {
			[obj setValue:validatedValue forKey:key];
		}

		return YES;
	} @catch (NSException *ex) {
		NSLog(@"*** Caught exception setting key \"%@\" : %@", key, ex);

		// Fail fast in Debug builds.
		#if DEBUG
		@throw ex;
		#else
		if (error != NULL) {
			*error = [NSError mtl_modelErrorWithException:ex];
		}

		return NO;
		#endif
	}
}

@interface MTLModel ()

// Inspects all properties of returned by +propertyKeys using
// +storageBehaviorForPropertyWithKey and caches the results.
+ (void)generateAndCacheStorageBehaviors;

// Returns a set of all property keys for which
// +storageBehaviorForPropertyWithKey returned MTLPropertyStorageTransitory.
+ (NSSet *)transitoryPropertyKeys;

// Returns a set of all property keys for which
// +storageBehaviorForPropertyWithKey returned MTLPropertyStoragePermanent.
+ (NSSet *)permanentPropertyKeys;

// Enumerates all properties of the receiver's class hierarchy, starting at the
// receiver, and continuing up until (but not including) MTLModel.
//
// The given block will be invoked multiple times for any properties declared on
// multiple classes in the hierarchy.
+ (void)enumeratePropertiesUsingBlock:(void (^)(objc_property_t property, BOOL *stop))block;

@end

@implementation MTLModel

#pragma mark Lifecycle

+ (void)generateAndCacheStorageBehaviors {
	NSMutableSet *transitoryKeys = [NSMutableSet set];
	NSMutableSet *permanentKeys = [NSMutableSet set];

	for (NSString *propertyKey in self.propertyKeys) {
		switch ([self storageBehaviorForPropertyWithKey:propertyKey]) {
			case MTLPropertyStorageNone:
				break;

			case MTLPropertyStorageTransitory:
				[transitoryKeys addObject:propertyKey];
				break;

			case MTLPropertyStoragePermanent:
				[permanentKeys addObject:propertyKey];
				break;
		}
	}

	// It doesn't really matter if we replace another thread's work, since we do
	// it atomically and the result should be the same.
	objc_setAssociatedObject(self, MTLModelCachedTransitoryPropertyKeysKey, transitoryKeys, OBJC_ASSOCIATION_COPY);
	objc_setAssociatedObject(self, MTLModelCachedPermanentPropertyKeysKey, permanentKeys, OBJC_ASSOCIATION_COPY);
}

+ (instancetype)modelWithDictionary:(NSDictionary *)dictionary error:(NSError **)error {
	return [[self alloc] initWithDictionary:dictionary error:error];
}

- (instancetype)init {
	// Nothing special by default, but we have a declaration in the header.
	return [super init];
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary error:(NSError **)error {
	self = [self init];
	if (self == nil) return nil;

    // 遍历字典，验证 value 通过后，再使用 KVC 设置属性值
	for (NSString *key in dictionary) {
		// Mark this as being autoreleased, because validateValue may return
		// a new object to be stored in this variable (and we don't want ARC to
		// double-free or leak the old or new values).
		__autoreleasing id value = [dictionary objectForKey:key];

		if ([value isEqual:NSNull.null]) value = nil;

		BOOL success = MTLValidateAndSetValue(self, key, value, YES, error);
		if (!success) return nil;
	}

	return self;
}

#pragma mark Reflection

+ (void)enumeratePropertiesUsingBlock:(void (^)(objc_property_t property, BOOL *stop))block {
	Class cls = self;
	BOOL stop = NO;

    // 从当前类到父类，一层一层遍历属性，直到 MTLModel 为止
	while (!stop && ![cls isEqual:MTLModel.class]) {
		unsigned count = 0;
        // 读取当前类的属性列表
		objc_property_t *properties = class_copyPropertyList(cls, &count);

        // 向父类继续查找
		cls = cls.superclass;
		if (properties == NULL) continue;

        // 当这块 scope 的代码执行完了，最后在执行这里的代码，也就是释放 properties 指针
        // MARK: 为什么不直接放到最后执行呢？
		@onExit {
			free(properties);
		};

        // 遍历当前这一层类的属性列表，并传给外面的 block
		for (unsigned i = 0; i < count; i++) {
			block(properties[i], &stop);
			if (stop) break;
		}
	}
}

/// 获取所有的属性名，除了没有实例变量的 readonly 属性和 MTLModel 自己的属性之外
+ (NSSet *)propertyKeys {
    // 读取缓存，如果有缓存就直接返回缓存
	NSSet *cachedKeys = objc_getAssociatedObject(self, MTLModelCachedPropertyKeysKey);
	if (cachedKeys != nil) return cachedKeys;

    // 获取所有的属性名
	NSMutableSet *keys = [NSMutableSet set];

    // 遍历所有属性
	[self enumeratePropertiesUsingBlock:^(objc_property_t property, BOOL *stop) {
		NSString *key = @(property_getName(property));

        // 筛选掉不需要转化的属性名
		if ([self storageBehaviorForPropertyWithKey:key] != MTLPropertyStorageNone) {
			 [keys addObject:key];
		}
	}];

	// It doesn't really matter if we replace another thread's work, since we do
	// it atomically and the result should be the same.
    // MARK: 上面这段注释啥意思？
    // 将获取的属性名列表缓存起来
	objc_setAssociatedObject(self, MTLModelCachedPropertyKeysKey, keys, OBJC_ASSOCIATION_COPY);

	return keys;
}

/// 临时性、一次性的 property
+ (NSSet *)transitoryPropertyKeys {
	NSSet *transitoryPropertyKeys = objc_getAssociatedObject(self, MTLModelCachedTransitoryPropertyKeysKey);

	if (transitoryPropertyKeys == nil) {
		[self generateAndCacheStorageBehaviors];
		transitoryPropertyKeys = objc_getAssociatedObject(self, MTLModelCachedTransitoryPropertyKeysKey);
	}

	return transitoryPropertyKeys;
}

/// 永久性的 property
+ (NSSet *)permanentPropertyKeys {
	NSSet *permanentPropertyKeys = objc_getAssociatedObject(self, MTLModelCachedPermanentPropertyKeysKey);

	if (permanentPropertyKeys == nil) {
		[self generateAndCacheStorageBehaviors];
		permanentPropertyKeys = objc_getAssociatedObject(self, MTLModelCachedPermanentPropertyKeysKey);
	}

	return permanentPropertyKeys;
}

/// 根据所有需要转换的属性名，生成一个 key 为属性名， value 为属性值的字典
- (NSDictionary *)dictionaryValue {
	NSSet *keys = [self.class.transitoryPropertyKeys setByAddingObjectsFromSet:self.class.permanentPropertyKeys];

    // 利用 KVC 将对象属性转成字典
	return [self dictionaryWithValuesForKeys:keys.allObjects];
}


// 计算一个属性 key 值的存储行为，也就是说 JSON 解析时是否需要转化
+ (MTLPropertyStorage)storageBehaviorForPropertyWithKey:(NSString *)propertyKey {
    // 获取属性名对应的 objc_property_t
	objc_property_t property = class_getProperty(self.class, propertyKey.UTF8String);

	if (property == NULL) return MTLPropertyStorageNone;

    // 将 objc_property_t 类型的属性信息转成 mtl_propertyAttributes 类型
	mtl_propertyAttributes *attributes = mtl_copyPropertyAttributes(property);
    
    // 这段代码块所在的 scope 执行完后，最后执行这段代码
	@onExit {
		free(attributes);
	}; 
	
    // 是否有 getter 和 setter
	BOOL hasGetter = [self instancesRespondToSelector:attributes->getter];
	BOOL hasSetter = [self instancesRespondToSelector:attributes->setter];
    

	if (!attributes->dynamic && attributes->ivar == NULL && !hasGetter && !hasSetter) {
        // 没有声明 @dynamic（@dynamic 就是要来告诉编译器，代码中用 @dynamic 修饰的属性，其 getter 和 setter 方法会在程序运行的时候或者用其他方式动态绑定，无须编译器自动合成，用 @dynamic 声明以便让编译器通过编译）
        // 该属性所对应的实例变量为 NULL
        // 没有 getter 和 setter
		return MTLPropertyStorageNone;
	} else if (attributes->readonly && attributes->ivar == NULL) {
        // 声明了 readonly，并且该属性所对应的实例变量为 NULL
        
		if ([self isEqual:MTLModel.class]) {
            // 如果是 MTLModel 的属性，就不参与转换
			return MTLPropertyStorageNone;
		} else {
			// Check superclass in case the subclass redeclares a property that
			// falls through
            // 如果不是 MTLModel 的属性，就向父类查找，以防该类重写了父类的这个属性
			return [self.superclass storageBehaviorForPropertyWithKey:propertyKey];
		}
	} else {
		return MTLPropertyStoragePermanent;
	}
}

#pragma mark Merging

- (void)mergeValueForKey:(NSString *)key fromModel:(NSObject<MTLModel> *)model {
	NSParameterAssert(key != nil);

	SEL selector = MTLSelectorWithCapitalizedKeyPattern("merge", key, "FromModel:");
	if (![self respondsToSelector:selector]) {
		if (model != nil) {
			[self setValue:[model valueForKey:key] forKey:key];
		}

		return;
	}

	IMP imp = [self methodForSelector:selector];
	void (*function)(id, SEL, id<MTLModel>) = (__typeof__(function))imp;
	function(self, selector, model);
}

- (void)mergeValuesForKeysFromModel:(id<MTLModel>)model {
	NSSet *propertyKeys = model.class.propertyKeys;

	for (NSString *key in self.class.propertyKeys) {
		if (![propertyKeys containsObject:key]) continue;

		[self mergeValueForKey:key fromModel:model];
	}
}

#pragma mark Validation

- (BOOL)validate:(NSError **)error {
	for (NSString *key in self.class.propertyKeys) {
		id value = [self valueForKey:key];

		BOOL success = MTLValidateAndSetValue(self, key, value, NO, error);
		if (!success) return NO;
	}

	return YES;
}

#pragma mark NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
	MTLModel *copy = [[self.class allocWithZone:zone] init];
	[copy setValuesForKeysWithDictionary:self.dictionaryValue];
	return copy;
}

#pragma mark NSObject

- (NSString *)description {
	NSDictionary *permanentProperties = [self dictionaryWithValuesForKeys:self.class.permanentPropertyKeys.allObjects];

	return [NSString stringWithFormat:@"<%@: %p> %@", self.class, self, permanentProperties];
}

// MARK: hash 值应该如何计算？
- (NSUInteger)hash {
	NSUInteger value = 0;

	for (NSString *key in self.class.permanentPropertyKeys) {
		value ^= [[self valueForKey:key] hash];
	}

	return value;
}

- (BOOL)isEqual:(MTLModel *)model {
	if (self == model) return YES;
	if (![model isMemberOfClass:self.class]) return NO;

	for (NSString *key in self.class.permanentPropertyKeys) {
		id selfValue = [self valueForKey:key];
		id modelValue = [model valueForKey:key];

		BOOL valuesEqual = ((selfValue == nil && modelValue == nil) || [selfValue isEqual:modelValue]);
		if (!valuesEqual) return NO;
	}

	return YES;
}

@end
