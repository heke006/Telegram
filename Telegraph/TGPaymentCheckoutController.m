#import "TGPaymentCheckoutController.h"

#import <LegacyComponents/LegacyComponents.h>

#import "TGDatabase.h"
#import "TGBotSignals.h"

#import "TGPaymentCheckoutHeaderItem.h"
#import "TGPaymentCheckoutPriceItem.h"
#import "TGVariantCollectionItem.h"

#import <LegacyComponents/TGModernButton.h>

#import "TGPaymentCheckoutInfoController.h"
#import "TGPaymentMethodController.h"

#import <LegacyComponents/TGProgressWindow.h>

#import "TGPaymentPasswordAlert.h"
#import "TGTwoStepConfigSignal.h"
#import "TGTwoStepVerifyPasswordSignal.h"

#import "TGStoredTmpPassword.h"
#import "TGTelegramNetworking.h"

#import "TGCustomAlertView.h"

#import "TGPaymentWebController.h"

#import "TGPaymentPasswordEntryController.h"
#import "TGAppDelegate.h"

#import "TGPasscodeSettingsController.h"

#import <LocalAuthentication/LocalAuthentication.h>
#import <PassKit/PassKit.h>
#import "Stripe.h"

#import "TGCurrencyFormatter.h"
#import "NSString+Stripe_CardBrands.h"

#import "TGShareSheetWindow.h"
#import "TGAttachmentSheetCheckmarkVariantItemView.h"
#import "TGShareSheetButtonItemView.h"

#import "TGAddPaymentCardController.h"

#import "TGShareSheetTitleItemView.h"

#import "TGPresentation.h"

static const NSTimeInterval passwordSaveDurationGeneric = 1.0 * 60.0 * 60.0;
static const NSTimeInterval passwordSaveDurationTouchId = 5.0 * 60.0 * 60.0;

static NSTimeInterval passwordSaveDuration() {
    static dispatch_once_t onceToken;
    static NSTimeInterval duration = 0.0;
    dispatch_once(&onceToken, ^{
        if ([TGPasscodeSettingsController supportsBiometrics:NULL]) {
            duration = passwordSaveDurationTouchId;
        } else {
            duration = passwordSaveDurationGeneric;
        }
    });
    return duration;
}

static NSArray *nativeApplePayProviders() {
    return @[
        @"stripe",
        @"sberbank",
        @"yandex"
    ];
}

static bool isNativeApplePayProvider(NSString *provider) {
    if (provider == nil) {
        return false;
    }
    return [nativeApplePayProviders() containsObject:provider];
}

@interface TGPaymentCheckoutController () <PKPaymentAuthorizationViewControllerDelegate> {
    SMetaDisposable *_disposable;
    
    TGMessage *_message;
    TGUser *_bot;
    
    TGCollectionMenuSection *_headerSection;
    TGCollectionMenuSection *_priceSection;
    TGCollectionMenuSection *_dataSection;
    
    TGPaymentForm *_paymentForm;
    
    UIView *_payButtonContainer;
    UIButton *_payButton;
    PKPaymentButton *_applePayButton;
    
    TGPaymentRequestedInfo *_currentInfo;
    TGValidatedRequestedInfo *_validatedInfo;
    TGShippingOption *_currentShippingOption;
    
    TGPaymentMethods *_paymentMethods;
    
    UIActivityIndicatorView *_activityIndicator;
    
    TGShareSheetWindow *_attachmentSheetWindow;
    
    TGVariantCollectionItem *_shippingMethodItem;
    
    bool _saveInfo;
    
    STPAPIClient *_apiClient;
    
    bool _overridePasswordMissing;
}

@end

@implementation TGPaymentCheckoutController

- (instancetype)initWithMessage:(TGMessage *)message {
    self = [super init];
    if (self != nil) {
        _bot = [TGDatabaseInstance() loadUser:(int32_t)message.fromUid];
        
        bool isTest = false;

        for (id attachment in message.mediaAttachments) {
            if ([attachment isKindOfClass:[TGInvoiceMediaAttachment class]]) {
                TGInvoiceMediaAttachment *media = attachment;
                isTest = media.isTest;
                
                break;
            }
        }
        
        self.title = [TGLocalized(@"Checkout.Title") stringByAppendingString: isTest ? @" (Test)" : @""];;
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:TGLocalized(@"Common.Cancel") style:UIBarButtonItemStylePlain target:self action:@selector(cancelPressed)];
        
        _message = message;
        _disposable = [[SMetaDisposable alloc] init];
        
        _headerSection = [[TGCollectionMenuSection alloc] initWithItems:@[]];
        _headerSection.insets = UIEdgeInsetsMake(0.0f, 0.0f, 0.0f, 0.0f);
        [self.menuSections addSection:_headerSection];
        
        _priceSection = [[TGCollectionMenuSection alloc] initWithItems:@[]];
        _priceSection.insets = UIEdgeInsetsMake(8.0f, 0.0f, 8.0f, 0.0f);
        [self.menuSections addSection:_priceSection];
        
        _dataSection = [[TGCollectionMenuSection alloc] initWithItems:@[]];
        _dataSection.insets = UIEdgeInsetsMake(0.0f, 0.0f, 16.0f, 0.0f);
        [self.menuSections addSection:_dataSection];
        
        _payButton = [[UIButton alloc] init];
        _payButton.adjustsImageWhenDisabled = false;
        _payButton.adjustsImageWhenHighlighted = false;
        [_payButton addTarget:self action:@selector(payPressed) forControlEvents:UIControlEventTouchUpInside];
        
        if (NSClassFromString(@"PKPaymentButton") != nil) {
            _applePayButton = [[PKPaymentButton alloc] initWithPaymentButtonType:PKPaymentButtonTypeBuy paymentButtonStyle:self.presentation.pallete.isDark ? PKPaymentButtonStyleWhite : PKPaymentButtonStyleBlack];
            [_applePayButton addTarget:self action:@selector(payPressed) forControlEvents:UIControlEventTouchUpInside];
        }
        
        _saveInfo = true;
        
        [self reloadItems];
        
        __weak TGPaymentCheckoutController *weakSelf = self;
        [_disposable setDisposable:[[[[TGBotSignals paymentForm:message.mid] mapToSignal:^SSignal *(TGPaymentForm *paymentForm) {
            __strong TGPaymentCheckoutController *strongSelf = weakSelf;
            if (strongSelf != nil) {
                bool validateNow = false;
                if (paymentForm.savedInfo != nil) {
                    strongSelf->_saveInfo = true;
                    if ([paymentForm.savedInfo satisfiesInvoice:paymentForm.invoice]) {
                        validateNow = true;
                    }
                } else {
                    strongSelf->_saveInfo = false;
                }
                if (validateNow) {
                    return [[[TGBotSignals validateRequestedPaymentInfo:message.mid info:paymentForm.savedInfo saveInfo:true] catch:^SSignal *(__unused id error) {
                        return [SSignal single:nil];
                    }] map:^id(TGValidatedRequestedInfo *validatedInfo) {
                        if (validatedInfo != nil) {
                            return @{@"paymentForm": paymentForm, @"validatedInfo": validatedInfo};
                        } else {
                            return @{@"paymentForm": paymentForm};
                        }
                    }];
                } else {
                    return [SSignal single:@{@"paymentForm": paymentForm}];
                }
            } else {
                return [SSignal single:@{@"paymentForm": paymentForm}];
            }
        }] deliverOn:[SQueue mainQueue]] startWithNext:^(NSDictionary *dict) {
            __strong TGPaymentCheckoutController *strongSelf = weakSelf;
            if (strongSelf != nil) {
                TGPaymentForm *paymentForm = dict[@"paymentForm"];
                TGValidatedRequestedInfo *validatedInfo = dict[@"validatedInfo"];
                strongSelf->_paymentForm = paymentForm;
                strongSelf->_currentInfo = paymentForm.savedInfo;
                strongSelf->_validatedInfo = validatedInfo;
                
                bool defaultToApplePay = false;
                if ([TGPaymentMethodController supportsApplePay] && (isNativeApplePayProvider(paymentForm.nativeProvider))) {
                    NSData *data = [TGDatabaseInstance() customProperty:@"payment.usedApplePay"];
                    if (data.length != 0) {
                        defaultToApplePay = true;
                    }
                }
                
                if (paymentForm.savedCredentials != nil) {
                    strongSelf->_paymentMethods = [[TGPaymentMethods alloc] initWithMethods:@[[[TGPaymentMethodSavedCredentialsCard alloc] initWithCard:paymentForm.savedCredentials]] selectedIndex:0];
                }
                
                if (defaultToApplePay) {
                    NSMutableArray *updatedPaymentMethods = [[NSMutableArray alloc] initWithArray:strongSelf->_paymentMethods.methods == nil ? @[] : strongSelf->_paymentMethods.methods];
                    [updatedPaymentMethods insertObject:[[TGPaymentMethodApplePay alloc] init] atIndex:0];
                    strongSelf->_paymentMethods = [[TGPaymentMethods alloc] initWithMethods:updatedPaymentMethods selectedIndex:0];
                }
                
                if ([strongSelf isViewLoaded]) {
                    UIView *snapshot = [strongSelf.collectionView snapshotViewAfterScreenUpdates:false];
                    [strongSelf.view insertSubview:snapshot aboveSubview:strongSelf.collectionView];
                    
                    strongSelf->_payButtonContainer.hidden = false;
                    strongSelf->_payButtonContainer.alpha = 0.0f;
                    [UIView animateWithDuration:0.2 animations:^{
                        snapshot.alpha = 0.0f;
                        strongSelf->_payButtonContainer.alpha = 1.0;
                    } completion:^(__unused BOOL finished) {
                        [snapshot removeFromSuperview];
                    }];
                    strongSelf.collectionView.scrollEnabled = true;
                    [strongSelf->_activityIndicator stopAnimating];
                    [strongSelf->_activityIndicator removeFromSuperview];
                    strongSelf->_activityIndicator = nil;
                }
                
                [strongSelf reloadItems];
            }
        } error:^(id error) {
            NSString *alertText = TGLocalized(@"Login.UnknownError");
            NSString *errorText = [[TGTelegramNetworking instance] extractNetworkErrorType:error];
            
            if ([errorText isEqualToString:@"PROVIDER_ACCOUNT_INVALID"]) {
                alertText = TGLocalized(@"Checkout.ErrorProviderAccountInvalid");
            } else if ([errorText isEqualToString:@"PROVIDER_ACCOUNT_TIMEOUT"]) {
                alertText = TGLocalized(@"Checkout.ErrorProviderAccountTimeout");
            } else if ([errorText isEqualToString:@"INVOICE_ALREADY_PAID"]) {
                alertText = TGLocalized(@"Checkout.ErrorInvoiceAlreadyPaid");
            }
            
            [TGCustomAlertView presentAlertWithTitle:nil message:alertText cancelButtonTitle:TGLocalized(@"Common.OK") okButtonTitle:nil completionBlock:nil];
        } completed:nil]];
    }
    return self;
}

- (void)dealloc {
    [_disposable dispose];
}

- (void)loadView {
    [super loadView];
    
    if (_paymentForm == nil) {
        _activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
        _activityIndicator.color = self.presentation.pallete.collectionMenuCommentColor;
        [self.view addSubview:_activityIndicator];
        [_activityIndicator startAnimating];
    }
    
    self.collectionView.backgroundColor = self.presentation.pallete.backgroundColor;
    self.collectionView.scrollEnabled = _paymentForm != nil;
    
    UIEdgeInsets safeAreaInset = self.controllerSafeAreaInset;
    _payButton.frame = CGRectMake(15.0f + safeAreaInset.left, 14.0f, self.view.frame.size.width - 30.0f - safeAreaInset.left - safeAreaInset.right, 48.0f);
    _applePayButton.frame = CGRectMake(15.0f + safeAreaInset.left, 14.0f, self.view.frame.size.width - 30.0f - safeAreaInset.left - safeAreaInset.right, 48.0f);
    _payButtonContainer = [[UIView alloc] initWithFrame:CGRectMake(0.0f, self.view.frame.size.height - 76.0f - safeAreaInset.bottom, self.view.frame.size.width, 76.0f + safeAreaInset.bottom)];
    _payButtonContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    _payButtonContainer.backgroundColor = [self.presentation.pallete.backgroundColor colorWithAlphaComponent:0.75f];
    _payButtonContainer.hidden = _paymentForm == nil;
    [self.view addSubview:_payButtonContainer];
    
    UIImage *payButtonImage;
    UIImage *payButtonHighlightedImage;
    UIImage *payDisabledButtonImage;
    
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(48.0f, 48.0f), false, 0.0f);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, self.presentation.pallete.paymentsPayButtonColor.CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(0.0f, 0.0f, 48.0f, 48.0f));
    payButtonImage = [UIGraphicsGetImageFromCurrentImageContext() stretchableImageWithLeftCapWidth:24 topCapHeight:24];
    UIGraphicsEndImageContext();
    
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(48.0f, 48.0f), false, 0.0f);
    context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, [self.presentation.pallete.paymentsPayButtonColor colorWithHueMultiplier:1.0f saturationMultiplier:1.0f brightnessMultiplier:0.8f].CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(0.0f, 0.0f, 48.0f, 48.0f));
    payButtonHighlightedImage = [UIGraphicsGetImageFromCurrentImageContext() stretchableImageWithLeftCapWidth:24 topCapHeight:24];
    UIGraphicsEndImageContext();
    
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(48.0f, 48.0f), false, 0.0f);
    context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, self.presentation.pallete.paymentsPayButtonDisabledColor.CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(0.0f, 0.0f, 48.0f, 48.0f));
    payDisabledButtonImage = [UIGraphicsGetImageFromCurrentImageContext() stretchableImageWithLeftCapWidth:24 topCapHeight:24];
    UIGraphicsEndImageContext();
    
    _payButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _applePayButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_payButton setTitleColor:self.presentation.pallete.accentContrastColor forState:UIControlStateNormal];
    _payButton.titleLabel.font = [UIFont boldSystemFontOfSize:17.0f];
    [_payButton setBackgroundImage:payButtonImage forState:UIControlStateNormal];
    [_payButton setBackgroundImage:payButtonHighlightedImage forState:UIControlStateHighlighted];
    [_payButton setBackgroundImage:payDisabledButtonImage forState:UIControlStateDisabled];
    [_payButtonContainer addSubview:_payButton];
    if (_applePayButton != nil) {
        [_payButtonContainer addSubview:_applePayButton];
    }
    
    [self setExplicitTableInset:UIEdgeInsetsMake(0.0f, 0, 76.0f, 0)];
    [self setExplicitScrollIndicatorInset:UIEdgeInsetsMake(0.0f, 0, 76.0f, 0)];
    if (![self _updateControllerInset:false])
        [self controllerInsetUpdated:UIEdgeInsetsZero];
}

- (void)controllerInsetUpdated:(UIEdgeInsets)previousInset {
    [super controllerInsetUpdated:previousInset];
    
    _activityIndicator.center = CGPointMake(self.view.frame.size.width / 2.0f, self.controllerInset.top + 163.0f + CGFloor((self.view.frame.size.height - (self.controllerInset.top + 163.0f)) / 2.0f));
}

- (void)layoutControllerForSize:(CGSize)size duration:(NSTimeInterval)duration {
    [super layoutControllerForSize:size duration:duration];
    
    _activityIndicator.center = CGPointMake(size.width / 2.0f, self.controllerInset.top + 163.0f + CGFloor((size.height - (self.controllerInset.top + 163.0f)) / 2.0f));
    
    UIEdgeInsets safeAreaInset = [self calculatedSafeAreaInset];
    _payButton.frame = CGRectMake(15.0f + safeAreaInset.left, 14.0f, size.width - 30.0f - safeAreaInset.left - safeAreaInset.right, 48.0f);
    _applePayButton.frame = CGRectMake(15.0f + safeAreaInset.left, 14.0f, size.width - 30.0f - safeAreaInset.left - safeAreaInset.right, 48.0f);
    _payButtonContainer.frame = CGRectMake(0.0f, size.height - 76.0f - safeAreaInset.bottom, size.width, 76.0f + safeAreaInset.bottom);
}

- (void)reloadItems {
    while (_headerSection.items.count > 0) {
        [_headerSection deleteItemAtIndex:0];
    }
    
    while (_priceSection.items.count > 0) {
        [_priceSection deleteItemAtIndex:0];
    }
    
    while (_dataSection.items.count > 0) {
        [_dataSection deleteItemAtIndex:0];
    }
    
    for (id attachment in _message.mediaAttachments) {
        if ([attachment isKindOfClass:[TGInvoiceMediaAttachment class]]) {
            TGInvoiceMediaAttachment *media = attachment;
            [_headerSection addItem:[[TGPaymentCheckoutHeaderItem alloc] initWithPhoto:[media webpage].photo title:media.title text:media.text label:_bot.displayName]];
            
            break;
        }
    }
    
    if (_paymentForm != nil) {
        int64_t totalPrice = 0;
        for (TGInvoicePrice *price in _paymentForm.invoice.prices) {
            
            NSString *string = [[TGCurrencyFormatter shared] formatAmount:price.amount currency:_paymentForm.invoice.currency];
            
            totalPrice += price.amount;
            
            [_priceSection addItem:[[TGPaymentCheckoutPriceItem alloc] initWithTitle:price.label value:string bold:false]];
        }
        if (_currentShippingOption != nil) {
            for (TGInvoicePrice *price in _currentShippingOption.prices) {
                NSString *string = [[TGCurrencyFormatter shared] formatAmount:price.amount currency:_paymentForm.invoice.currency];
                
                totalPrice += price.amount;
                
                [_priceSection addItem:[[TGPaymentCheckoutPriceItem alloc] initWithTitle:price.label value:string bold:false]];
            }
        }
        if (totalPrice != 0) {
            NSString *string = [[TGCurrencyFormatter shared] formatAmount:totalPrice currency:_paymentForm.invoice.currency];
            
            [_priceSection addItem:[[TGPaymentCheckoutPriceItem alloc] initWithTitle:TGLocalized(@"Checkout.TotalAmount") value:string bold:true]];
            [_payButton setTitle:[NSString stringWithFormat:TGLocalized(@"Checkout.PayPrice"), string] forState:UIControlStateNormal];
        } else {
            [_payButton setTitle:TGLocalized(@"Checkout.PayNone") forState:UIControlStateNormal];
        }
        
        NSString *paymentMethod = @"";
        UIImage *paymentMethodIcon = nil;
        if (_paymentMethods != nil && _paymentMethods.selectedIndex != NSNotFound) {
            paymentMethod = [_paymentMethods.methods[_paymentMethods.selectedIndex] title];
            if ([_paymentMethods.methods[_paymentMethods.selectedIndex] isKindOfClass:[TGPaymentMethodApplePay class]]) {
                paymentMethodIcon = [UIImage imageNamed:@"Apple_Pay_Payment_Mark.png"];
            }
        }
        TGVariantCollectionItem *paymentMethodItem = [[TGVariantCollectionItem alloc] initWithTitle:TGLocalized(@"Checkout.PaymentMethod") variant:paymentMethod action:@selector(paymentMethodPressed)];
        paymentMethodItem.variantIcon = paymentMethodIcon;
        paymentMethodItem.deselectAutomatically = true;
        [_dataSection addItem:paymentMethodItem];
        
        if (_paymentForm.invoice.shippingAddressRequested) {
            [_dataSection addItem:[[TGVariantCollectionItem alloc] initWithTitle:TGLocalized(@"Checkout.ShippingAddress") variant:_currentInfo.shippingAddress != nil ? [_currentInfo.shippingAddress descriptionWithSeparator:@", "] : @"" action:@selector(shippingAddressPressed)]];
            
            if (_validatedInfo != nil && _validatedInfo.shippingOptions.count != 0) {
                _shippingMethodItem = [[TGVariantCollectionItem alloc] initWithTitle:TGLocalized(@"Checkout.ShippingMethod") variant:_currentShippingOption != nil ? _currentShippingOption.title : @""  action:@selector(shippingMethodPressed)];
                _shippingMethodItem.deselectAutomatically = true;
                [_dataSection addItem:_shippingMethodItem];
            } else {
                _shippingMethodItem = nil;
            }
        } else {
            _shippingMethodItem = nil;
        }
        
        if (_paymentForm.invoice.nameRequested) {
            [_dataSection addItem:[[TGVariantCollectionItem alloc] initWithTitle:TGLocalized(@"Checkout.Name") variant:_currentInfo.name != nil ? _currentInfo.name : @"" action:@selector(namePressed)]];
        }
        
        if (_paymentForm.invoice.emailRequested) {
            [_dataSection addItem:[[TGVariantCollectionItem alloc] initWithTitle:TGLocalized(@"Checkout.Email") variant:_currentInfo.email != nil ? _currentInfo.email : @"" action:@selector(emailPressed)]];
        }
        
        if (_paymentForm.invoice.phoneRequested) {
            [_dataSection addItem:[[TGVariantCollectionItem alloc] initWithTitle:TGLocalized(@"Checkout.Phone") variant:_currentInfo.phone != nil ? _currentInfo.phone : @"" action:@selector(phonePressed)]];
        }
    }
    
    bool buttonEnabled = true;
    
    if (_paymentForm.invoice.requiresShippingInfo) {
        if (_validatedInfo == nil) {
            buttonEnabled = false;
        }
    }
    
    if (_validatedInfo != nil && _validatedInfo.shippingOptions.count != 0 && _currentShippingOption == nil) {
        //buttonEnabled = false;
    }
    
    bool isApplePay = false;
    if (_paymentMethods == nil || _paymentMethods.selectedIndex == NSNotFound) {
        //buttonEnabled = false;
    } else if ([_paymentMethods.methods[_paymentMethods.selectedIndex] isKindOfClass:[TGPaymentMethodApplePay class]]) {
        isApplePay = true;
    }
    
    _applePayButton.hidden = !isApplePay;
    _payButton.hidden = isApplePay;
    
    _payButton.enabled = buttonEnabled;
    _applePayButton.enabled = buttonEnabled;
    [self.collectionView reloadData];
}

- (void)cancelPressed {
    [self.presentingViewController dismissViewControllerAnimated:true completion:nil];
}

- (void)shippingMethodPressed {
    if (_validatedInfo != nil && _validatedInfo.shippingOptions.count != 0) {
        [self showShippingMethodSheet];
    }
}

- (void)paymentMethodPressed {
    [self showPaymentMethodSheet];
}

- (void)shippingAddressPressed {
    [self openInfoController:TGPaymentCheckoutInfoControllerFocusAddress];
}

- (void)namePressed {
    [self openInfoController:TGPaymentCheckoutInfoControllerFocusName];
}

- (void)emailPressed {
    [self openInfoController:TGPaymentCheckoutInfoControllerFocusEmail];
}

- (void)phonePressed {
    [self openInfoController:TGPaymentCheckoutInfoControllerFocusPhone];
}

- (void)openInfoController:(TGPaymentCheckoutInfoControllerFocus)focus {
    TGPaymentCheckoutInfoController *infoController = [[TGPaymentCheckoutInfoController alloc] initWithMessageId:_message.mid invoice:_paymentForm.invoice canSaveInfo:true enableSaveInfoByDefault:_saveInfo currentInfo:_currentInfo focus:focus];
    __weak TGPaymentCheckoutController *weakSelf = self;
    infoController.completed = ^(TGPaymentRequestedInfo *info, TGValidatedRequestedInfo *validatedInfo, bool saveInfo) {
        __strong TGPaymentCheckoutController *strongSelf = weakSelf;
        if (strongSelf != nil) {
            strongSelf->_currentInfo = info;
            strongSelf->_validatedInfo = validatedInfo;
            strongSelf->_saveInfo = saveInfo;
            if (strongSelf->_currentShippingOption != nil) {
                if (![validatedInfo.shippingOptions containsObject:strongSelf->_currentShippingOption]) {
                    strongSelf->_currentShippingOption = nil;
                }
            }
            
            [strongSelf dismissViewControllerAnimated:true completion:nil];
            
            [strongSelf reloadItems];
        }
    };
    TGNavigationController *navigationController = [TGNavigationController navigationControllerWithRootController:infoController];
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        navigationController.presentationStyle = TGNavigationControllerPresentationStyleDefault;
        navigationController.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    [self presentViewController:navigationController animated:true completion:nil];
}

- (void)payPressed {
    if (_paymentMethods == nil || _paymentMethods.selectedIndex == NSNotFound) {
        [self showPaymentMethodSheet];
        return;
    }
    
    if (_shippingMethodItem != nil && _currentShippingOption == nil) {
        [self showShippingMethodSheet];
        return;
    }
    
    NSData *alertData = nil;
    if (_bot.isVerified) {
        uint8_t one = 1;
        alertData = [NSData dataWithBytes:&one length:1];
    } else {
        alertData = [TGDatabaseInstance() conversationCustomPropertySync:_bot.uid name:murMurHash32(@"PaymentLiabilityAlertDisplayed")];
    }
#ifdef DEBUG
    alertData = nil;
#endif
    
    if (alertData.length == 0 && ![_paymentMethods.methods[_paymentMethods.selectedIndex] isKindOfClass:[TGPaymentMethodApplePay class]]) {
        TGUser *paymentUser = [TGDatabaseInstance() loadUser:_paymentForm.providerId];
        __weak TGPaymentCheckoutController *weakSelf = self;
        
        TGCustomAlertView *alertView = [TGCustomAlertView presentAlertWithTitle:TGLocalized(@"Checkout.LiabilityAlertTitle") message:[@"\n" stringByAppendingString:[NSString stringWithFormat:TGLocalized(@"Checkout.LiabilityAlert"), _bot.displayName, paymentUser == nil ? @"" : paymentUser.displayName]] cancelButtonTitle:TGLocalized(@"Common.Cancel") okButtonTitle:TGLocalized(@"Common.OK") completionBlock:^(__unused bool okButtonPressed) {
            __strong TGPaymentCheckoutController *strongSelf = weakSelf;
            if (strongSelf != nil) {
                uint8_t one = 1;
                NSData *oneData = [NSData dataWithBytes:&one length:1];
                [TGDatabaseInstance() setConversationCustomProperty:strongSelf->_bot.uid name:murMurHash32(@"PaymentLiabilityAlertDisplayed") value:oneData];
                [strongSelf proceedToPayment];
            }
        }];
        alertView.messageLabel.textAlignment = NSTextAlignmentLeft;
    } else {
        [self proceedToPayment];
    }
}
    
- (void)proceedToPayment {
    id<TGPaymentMethod> paymentMethod = (_paymentMethods != nil && _paymentMethods.selectedIndex != NSNotFound) ? _paymentMethods.methods[_paymentMethods.selectedIndex] : nil;
    if (paymentMethod != nil) {
        if ([paymentMethod isKindOfClass:[TGPaymentMethodApplePay class]]) {
            PKPaymentRequest *request = [[PKPaymentRequest alloc] init];
            
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:[_paymentForm.nativeParams dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            request.merchantIdentifier = dict[@"apple_pay_merchant_id"];
            if (request.merchantIdentifier != nil) {
                request.supportedNetworks = @[PKPaymentNetworkVisa, PKPaymentNetworkAmex, PKPaymentNetworkMasterCard];
                request.merchantCapabilities = PKMerchantCapability3DS;
                request.countryCode = @"US";
                request.currencyCode = [_paymentForm.invoice.currency uppercaseString];
                
                if (_paymentForm.invoice.shippingAddressRequested || _paymentForm.invoice.nameRequested || _paymentForm.invoice.emailRequested || _paymentForm.invoice.phoneRequested) {
                    PKContact *shippingContact = [[PKContact alloc] init];
                    
                    if (_paymentForm.invoice.shippingAddressRequested) {
                        request.requiredShippingAddressFields |= PKAddressFieldPostalAddress;
                        
                        CNMutablePostalAddress *postalAddress = [[CNMutablePostalAddress alloc] init];

                        NSString *lines = _currentInfo.shippingAddress.streetLine1;
                        if (_currentInfo.shippingAddress.streetLine2.length != 0) {
                            lines = [lines stringByAppendingFormat:@"\n%@", _currentInfo.shippingAddress.streetLine2];
                        }
                        postalAddress.street = lines;
                        postalAddress.state = _currentInfo.shippingAddress.state;
                        postalAddress.city =  _currentInfo.shippingAddress.city;
                        postalAddress.ISOCountryCode = _currentInfo.shippingAddress.countryIso2;
                        postalAddress.postalCode = _currentInfo.shippingAddress.postCode;
                        
                        shippingContact.postalAddress = postalAddress;
                    }
                    
                    if (_paymentForm.invoice.nameRequested) {
                        request.requiredShippingAddressFields |= PKAddressFieldName;
                        NSPersonNameComponents *nameComponents = [[NSPersonNameComponents alloc] init];
                        nameComponents.givenName = _currentInfo.name;
                        shippingContact.name = nameComponents;
                    }
                    
                    if (_paymentForm.invoice.emailRequested) {
                        request.requiredShippingAddressFields |= PKAddressFieldEmail;
                        shippingContact.emailAddress = _currentInfo.email;
                    }
                    
                    if (_paymentForm.invoice.phoneRequested) {
                        request.requiredShippingAddressFields |= PKAddressFieldPhone;
                        shippingContact.phoneNumber = [[CNPhoneNumber alloc] initWithStringValue:_currentInfo.phone];
                    }
                    
                    request.shippingContact = shippingContact;
                }
                
                NSMutableArray *items = [[NSMutableArray alloc] init];
                
                int64_t totalAmount = 0;
                for (TGInvoicePrice *price in _paymentForm.invoice.prices) {
                    totalAmount += price.amount;
                    [items addObject:[PKPaymentSummaryItem summaryItemWithLabel:price.label amount:[[NSDecimalNumber alloc] initWithDouble:price.amount * 0.01]]];
                }
                if (_currentShippingOption != nil) {
                    for (TGInvoicePrice *price in _currentShippingOption.prices) {
                        totalAmount += price.amount;
                        [items addObject:[PKPaymentSummaryItem summaryItemWithLabel:price.label amount:[[NSDecimalNumber alloc] initWithDouble:price.amount * 0.01]]];
                    }
                }
                
                [items addObject:[PKPaymentSummaryItem summaryItemWithLabel:_bot.displayName amount:[[NSDecimalNumber alloc] initWithDouble:totalAmount * 0.01]]];
                
                request.paymentSummaryItems = items;
                
                PKPaymentAuthorizationViewController *controller = [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest:request];
                if (controller != nil) {
                    controller.delegate = self;
                    [self presentViewController:controller animated:true completion:nil];
                }
            }
        } else if ([paymentMethod isKindOfClass:[TGPaymentMethodStripeToken class]]) {
            TGPaymentMethodStripeToken *token = (TGPaymentMethodStripeToken *)paymentMethod;
            [self payWithCredentials:token.token isApplePay:false completion:nil];
        } else if ([paymentMethod isKindOfClass:[TGPaymentMethodWebToken class]]) {
            TGPaymentMethodWebToken *token = (TGPaymentMethodWebToken *)paymentMethod;
            [self payWithCredentials:[[TGPaymentCredentialsWebToken alloc] initWithData:token.jsonData saveCredentials:token.saveCredentials] isApplePay:false completion:nil];
        } else if ([paymentMethod isKindOfClass:[TGPaymentMethodSavedCredentialsCard class]]) {
            TGPaymentMethodSavedCredentialsCard *card = (TGPaymentMethodSavedCredentialsCard *)paymentMethod;
            
            NSData *currentStoredPasswordData = [TGDatabaseInstance() customProperty:@"paymentsTmpPassword"];
            TGStoredTmpPassword *currentStoredPassword = nil;
            if (currentStoredPasswordData.length != 0) {
                currentStoredPassword = [NSKeyedUnarchiver unarchiveObjectWithData:currentStoredPasswordData];
            }
            
            int32_t timestamp = (int32_t)[[TGTelegramNetworking instance] approximateRemoteTime];
            if (currentStoredPassword != nil && timestamp < currentStoredPassword.validUntil - 10) {
                if ([TGPasscodeSettingsController supportsBiometrics:NULL]) {
                    LAContext *context = [[LAContext alloc] init];
                    
                    __weak TGPaymentCheckoutController *weakSelf = self;
                    
                    NSError *error = nil;
                    if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&error]) {
                        context.localizedFallbackTitle = TGLocalized(@"Checkout.EnterPassword");
                        NSString *reason = TGLocalized(@"Checkout.PayWithTouchId");
                        if ([context respondsToSelector:@selector(biometryType)] && context.biometryType == LABiometryTypeFaceID)
                            reason = TGLocalized(@"Checkout.PayWithFaceId");
                            
                        [context evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics localizedReason:reason reply:^(BOOL success, NSError *error)
                        {
                            if (error != nil)
                            {
                                if (error.code == -3) {
                                    TGDispatchOnMainThread(^{
                                        TGDispatchAfter(0.3, dispatch_get_main_queue(), ^{
                                            __strong TGPaymentCheckoutController *strongSelf = weakSelf;
                                            if (strongSelf != nil) {
                                                [strongSelf requestPasswordAndPay:card];
                                            }
                                        });
                                    });
                                } else {
                                    TGDispatchOnMainThread(^{
                                        __strong TGPaymentCheckoutController *strongSelf = weakSelf;
                                        if (strongSelf != nil) {
                                            //[strongSelf requestPasswordAndPay:card];
                                        }
                                    });
                                }
                            }
                            else
                            {
                                if (success) {
                                    TGDispatchOnMainThread(^{
                                        __strong TGPaymentCheckoutController *strongSelf = weakSelf;
                                        if (strongSelf != nil) {
                                            [self payWithCredentials:[[TGPaymentCredentialsSaved alloc] initWithCardId:card.card.cardId tmpPassword:currentStoredPassword.data] isApplePay:false completion:nil];
                                        }
                                    });
                                } else {
                                    TGDispatchOnMainThread(^{
                                        TGDispatchAfter(0.3, dispatch_get_main_queue(), ^{
                                            __strong TGPaymentCheckoutController *strongSelf = weakSelf;
                                            if (strongSelf != nil) {
                                                [strongSelf requestPasswordAndPay:card];
                                            }
                                        });
                                    });
                                }
                            }
                        }];
                    } else {
                        [self requestPasswordAndPay:card];
                    }
                } else {
                    [self payWithCredentials:[[TGPaymentCredentialsSaved alloc] initWithCardId:card.card.cardId tmpPassword:currentStoredPassword.data] isApplePay:false completion:nil];
                }
            } else {
                [self requestPasswordAndPay:card];
            }
        }
    }
}

- (void)requestPasswordAndPay:(TGPaymentMethodSavedCredentialsCard *)card {
    __weak TGPaymentCheckoutController *weakSelf = self;
    
    TGPaymentPasswordEntryController *controller = [[TGPaymentPasswordEntryController alloc] initWithCardTitle:_paymentForm.savedCredentials.title];
    controller.presentation = self.presentation;
    __weak TGPaymentPasswordEntryController *weakController = controller;
    controller.payWithPassword = ^SSignal *(NSString *password) {
        __strong TGPaymentCheckoutController *strongSelf = weakSelf;
        if (strongSelf != nil) {
            SSignal *signal = [[TGTwoStepConfigSignal twoStepConfig] mapToSignal:^SSignal *(TGTwoStepConfig *config) {
                return [TGTwoStepVerifyPasswordSignal tmpPassword:password config:config durationSeconds:(int32_t)passwordSaveDuration()];
            }];
            return [[signal onNext:^(TGStoredTmpPassword *tmpPassword) {
                TGDispatchOnMainThread(^{
                    __strong TGPaymentCheckoutController *strongSelf = weakSelf;
                    if (strongSelf != nil) {
                        [strongSelf payWithObtainedTmpPassword:tmpPassword card:card];
                    }
                });
            }] onError:^(id error) {
                TGDispatchOnMainThread(^{
                    NSString *errorType = [[TGTelegramNetworking instance] extractNetworkErrorType:error];
                    if ([errorType hasPrefix:@"FLOOD_"]) {
                        __strong TGPaymentPasswordEntryController *strongController = weakController;
                        if (strongController != nil) {
                            [strongController dismissAnimated];
                        }
                        
                        [TGCustomAlertView presentAlertWithTitle:nil message:TGLocalized(@"LoginPassword.FloodError") cancelButtonTitle:TGLocalized(@"Common.OK") okButtonTitle:nil completionBlock:nil];
                    }
                });
            }];
        } else {
            return [SSignal fail:nil];
        }
    };
    [TGAppDelegateInstance.window presentOverlayController:controller];
}

- (void)payWithObtainedTmpPassword:(TGStoredTmpPassword *)tmpPassword card:(TGPaymentMethodSavedCredentialsCard *)card {
    NSString *saveText = @"";
    int32_t duration = (int32_t)passwordSaveDuration();
    NSString *durationString = [TGStringUtils stringForMessageTimerSeconds:duration];
    
    bool hasFaceId = false;
    if ([TGPasscodeSettingsController supportsBiometrics:&hasFaceId]) {
        saveText = [NSString stringWithFormat:hasFaceId ? TGLocalized(@"Checkout.SavePasswordTimeoutAndFaceId") : TGLocalized(@"Checkout.SavePasswordTimeoutAndTouchId"), durationString];
    } else {
        saveText = [NSString stringWithFormat:TGLocalized(@"Checkout.SavePasswordTimeout"), durationString];
    }
    
    __weak TGPaymentCheckoutController *weakSelf = self;
    [TGCustomAlertView presentAlertWithTitle:nil message:saveText cancelButtonTitle:TGLocalized(@"Common.No") okButtonTitle:TGLocalized(@"Common.Yes") completionBlock:^(bool okButtonPressed)
    {
        __strong TGPaymentCheckoutController *strongSelf = weakSelf;
        if (strongSelf != nil) {
            if (okButtonPressed) {
                [TGDatabaseInstance() setCustomProperty:@"paymentsTmpPassword" value:[NSKeyedArchiver archivedDataWithRootObject:tmpPassword]];
            } else {
                [TGDatabaseInstance() setCustomProperty:@"paymentsTmpPassword" value:[NSData data]];
            }
            [strongSelf payWithCredentials:[[TGPaymentCredentialsSaved alloc] initWithCardId:card.card.cardId tmpPassword:tmpPassword.data] isApplePay:false completion:nil];
        }
    }];
}

- (void)payWithCredentials:(id)credentials isApplePay:(bool)isApplePay completion:(void (^)(bool))completion {
    if (isApplePay) {
        uint8_t one = 1;
        [TGDatabaseInstance() setCustomProperty:@"payment.usedApplePay" value:[NSData dataWithBytes:&one length:1]];
    } else {
        [TGDatabaseInstance() setCustomProperty:@"payment.usedApplePay" value:[NSData data]];
    }
    
    TGProgressWindow *progressWindow = [[TGProgressWindow alloc] init];
    if (completion == nil) {
        [progressWindow showWithDelay:0.1];
    }
    __weak TGPaymentCheckoutController *weakSelf = self;
    [_disposable setDisposable:[[[[TGBotSignals sendPayment:_message.mid infoId:_validatedInfo.infoId shippingOptionId:_currentShippingOption.optionId credentials:credentials] deliverOn:[SQueue mainQueue]] onDispose:^{
        TGDispatchOnMainThread(^{
            [progressWindow dismiss:true];
        });
    }] startWithNext:^(NSString *confirmationUrl) {
        if (completion) {
            completion(true);
        }
        
        __strong TGPaymentCheckoutController *strongSelf = weakSelf;
        if (strongSelf != nil) {
            if (confirmationUrl != nil) {
                [progressWindow dismiss:true];
                if (strongSelf.presentedViewController != nil) {
                    [strongSelf dismissViewControllerAnimated:true completion:nil];
                }
                
                TGPaymentWebController *confirmationController = [[TGPaymentWebController alloc] initWithUrl:confirmationUrl confirmation:true canSave:false allowSaving:false];
                __weak TGPaymentWebController *weakConfirmationController = confirmationController;
                confirmationController.completedConfirmation = ^{
                    __strong TGPaymentWebController *strongConfirmationController = weakConfirmationController;
                    if (strongConfirmationController != nil) {
                        [strongConfirmationController.presentingViewController dismissViewControllerAnimated:true completion:nil];
                    }
                };
                [self.navigationController setViewControllers:@[confirmationController] animated:true];
            } else {
                [progressWindow dismissWithSuccess];
                [strongSelf cancelPressed];
            }
        }
    } error:^(id error) {
        if (completion) {
            completion(false);
        }
        
        if ([error isKindOfClass:[MTRpcError class]] && ((MTRpcError *)error).errorCode != 406) {
            NSString *alertText = TGLocalized(@"Checkout.ErrorGeneric");
            NSString *errorText = [[TGTelegramNetworking instance] extractNetworkErrorType:error];
            
            if ([errorText isEqualToString:@"BOT_PRECHECKOUT_FAILED"]) {
                alertText = TGLocalized(@"Checkout.ErrorPrecheckoutFailed");
            } else if ([errorText isEqualToString:@"PAYMENT_FAILED"]) {
                alertText = TGLocalized(@"Checkout.ErrorPaymentFailed");
            } else if ([errorText isEqualToString:@"INVOICE_ALREADY_PAID"]) {
                alertText = TGLocalized(@"Checkout.ErrorInvoiceAlreadyPaid");
            }
            
            [TGCustomAlertView presentAlertWithTitle:nil message:alertText cancelButtonTitle:TGLocalized(@"Common.OK") okButtonTitle:nil completionBlock:nil];
        }
    } completed:nil]];
}

- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)__unused controller
                       didAuthorizePayment:(PKPayment *)payment
                                completion:(void (^)(PKPaymentAuthorizationStatus status))completion {
    if (_paymentForm.invoice.shippingAddressRequested || _paymentForm.invoice.nameRequested || _paymentForm.invoice.emailRequested || _paymentForm.invoice.phoneRequested) {
        TGPostAddress *shippingAddress = nil;
        NSString *name = nil;
        NSString *email = nil;
        NSString *phone = nil;
        
        if (_paymentForm.invoice.shippingAddressRequested) {
            shippingAddress = [[TGPostAddress alloc] initWithStreetLine1:payment.shippingContact.postalAddress.street streetLine2:payment.shippingContact.postalAddress.subLocality city:payment.shippingContact.postalAddress.city state:payment.shippingContact.postalAddress.state countryIso2:payment.shippingContact.postalAddress.ISOCountryCode postCode:payment.shippingContact.postalAddress.postalCode];
        }
        
        if (_paymentForm.invoice.nameRequested) {
            NSPersonNameComponentsFormatter *formatter = [[NSPersonNameComponentsFormatter alloc] init];
            formatter.style = NSPersonNameComponentsFormatterStyleDefault;
            name = [formatter stringFromPersonNameComponents:payment.shippingContact.name];
        }
        
        if (_paymentForm.invoice.emailRequested) {
            email = payment.shippingContact.emailAddress;
        }
        
        if (_paymentForm.invoice.phoneRequested) {
            phone = [payment.shippingContact.phoneNumber stringValue];
        }
        
        if (!TGObjectCompare(shippingAddress, _currentInfo.shippingAddress) || !TGObjectCompare(name, _currentInfo.name) || !TGObjectCompare(email, _currentInfo.email) || !TGObjectCompare(phone, _currentInfo.phone)) {
            TGPaymentRequestedInfo *info = [[TGPaymentRequestedInfo alloc] initWithName:name phone:phone email:email shippingAddress:shippingAddress];
            __weak TGPaymentCheckoutController *weakSelf = self;
            [_disposable setDisposable:[[[[TGBotSignals validateRequestedPaymentInfo:_message.mid info:info saveInfo:_saveInfo] deliverOn:[SQueue mainQueue]] onDispose:^{
                
            }] startWithNext:^(TGValidatedRequestedInfo *next) {
                __strong TGPaymentCheckoutController *strongSelf = weakSelf;
                if (strongSelf != nil) {
                    strongSelf->_currentInfo = info;
                    strongSelf->_validatedInfo = next;
                    
                    bool fail = false;
                    if (strongSelf->_currentShippingOption != nil) {
                        if (![next.shippingOptions containsObject:strongSelf->_currentShippingOption]) {
                            strongSelf->_currentShippingOption = nil;
                            fail = true;
                        }
                    }
                    
                    [strongSelf reloadItems];
                    
                    if (fail) {
                        if (completion) {
                            completion(PKPaymentAuthorizationStatusFailure);
                        }
                    } else {
                        [strongSelf continuePassKitPaymentWithCompletion:completion payment:payment];
                    }
                }
            } error:^(__unused id error) {
                if (completion) {
                    completion(PKPaymentAuthorizationStatusFailure);
                }
            } completed:nil]];
        } else {
            [self continuePassKitPaymentWithCompletion:completion payment:payment];
        }
    } else {
        [self continuePassKitPaymentWithCompletion:completion payment:payment];
    }
}

- (void)continuePassKitPaymentWithCompletion:(void (^)(PKPaymentAuthorizationStatus status))completion payment:(PKPayment *)payment {
    if ([_paymentForm.nativeProvider isEqualToString:@"stripe"]) {
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:[_paymentForm.nativeParams dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSString *publishableKey = dict[@"publishable_key"];
        if (publishableKey == nil) {
            if (completion) {
                completion(PKPaymentAuthorizationStatusFailure);
            }
            return;
        }
        
        STPPaymentConfiguration *configuration = [[STPPaymentConfiguration sharedConfiguration] copy];
        configuration.smsAutofillDisabled = true;
        configuration.publishableKey = publishableKey;
        configuration.appleMerchantIdentifier = @"merchant.ph.telegra.Telegraph";
        
        _apiClient = [[STPAPIClient alloc] initWithConfiguration:configuration];
        
        __weak TGPaymentCheckoutController *weakSelf = self;
        [_apiClient createTokenWithPayment:payment completion:^(STPToken *token, NSError *error) {
            TGDispatchOnMainThread(^{
                __strong TGPaymentCheckoutController *strongSelf = weakSelf;
                if (error != nil || token == nil) {
                    completion(PKPaymentAuthorizationStatusFailure);
                } else {
                    NSString *last4 = token.card.last4;
                    NSString *brand = [NSString stp_stringWithCardBrand:token.card.brand];
                    
                    TGPaymentCredentialsStripeToken *stripeToken = [[TGPaymentCredentialsStripeToken alloc] initWithTokenId:token.tokenId title:[[brand stringByAppendingString:@"*"] stringByAppendingString:last4] saveCredentials:false];
                    [strongSelf payWithCredentials:stripeToken isApplePay:true completion:^(bool result) {
                        completion(result ? PKPaymentAuthorizationStatusSuccess : PKPaymentAuthorizationStatusFailure);
                    }];
                }
            });
        }];
    } else {
        NSString *paymentString = [[NSString alloc] initWithData:payment.token.paymentData encoding:NSUTF8StringEncoding];
        if (paymentString != nil) {
            [self payWithCredentials:[[TGPaymentCredentialsApplePay alloc] initWithData:paymentString] isApplePay:true completion:^(bool result) {
                completion(result ? PKPaymentAuthorizationStatusSuccess : PKPaymentAuthorizationStatusFailure);
            }];
        } else {
            completion(PKPaymentAuthorizationStatusFailure);
        }
    }
}

- (void)paymentAuthorizationViewControllerDidFinish:(PKPaymentAuthorizationViewController *)__unused controller {
    [_disposable setDisposable:nil];
    [self dismissViewControllerAnimated:true completion:nil];
}

- (void)showShippingMethodSheet {
    [_attachmentSheetWindow dismissAnimated:true completion:nil];
    
    __weak TGPaymentCheckoutController *weakSelf = self;
    _attachmentSheetWindow = [[TGShareSheetWindow alloc] init];
    _attachmentSheetWindow.dismissalBlock = ^
    {
        __strong TGPaymentCheckoutController *strongSelf = weakSelf;
        if (strongSelf == nil)
            return;
        
        strongSelf->_attachmentSheetWindow.rootViewController = nil;
        strongSelf->_attachmentSheetWindow = nil;
    };
    
    NSMutableArray *items = [[NSMutableArray alloc] init];
    
    [items addObject:[[TGShareSheetTitleItemView alloc] initWithTitle:TGLocalized(@"Checkout.ShippingOption.Title")]];
    
    for (TGShippingOption *option in _validatedInfo.shippingOptions) {
        int64_t totalPrice = 0;
        
        for (TGInvoicePrice *price in option.prices) {
            totalPrice += price.amount;
        }
        
        NSString *string = [[TGCurrencyFormatter shared] formatAmount:totalPrice currency:_paymentForm.invoice.currency];
        
        TGAttachmentSheetCheckmarkVariantItemView *itemView = [[TGAttachmentSheetCheckmarkVariantItemView alloc] initWithTitle:option.title variant:string checked:[_currentShippingOption isEqual:option]];
        itemView.disableAutoCheck = true;
        itemView.disableInsetIfNotChecked = _currentShippingOption == nil;
        itemView.onCheckedChanged = ^(bool value) {
            if (value) {
                __strong TGPaymentCheckoutController *strongSelf = weakSelf;
                if (strongSelf != nil) {
                    strongSelf->_currentShippingOption = option;
                    NSIndexPath *indexPath = [strongSelf indexPathForItem:strongSelf->_shippingMethodItem];
                    if (indexPath != nil) {
                        UICollectionViewCell *cell = [strongSelf.collectionView cellForItemAtIndexPath:indexPath];
                        CGFloat verticalOffset = [cell convertRect:[cell bounds] toView:strongSelf.view].origin.y;
                        UIView *snapshot = [strongSelf.collectionView snapshotViewAfterScreenUpdates:false];
                        
                        [strongSelf reloadItems];
                        [strongSelf.collectionView layoutSubviews];
                        
                        NSIndexPath *updatedIndexPath = [strongSelf indexPathForItem:strongSelf->_shippingMethodItem];
                        if (updatedIndexPath != nil) {
                            [strongSelf.view insertSubview:snapshot aboveSubview:strongSelf.collectionView];
                            
                            [UIView animateWithDuration:0.2 animations:^{
                                snapshot.alpha = 0.0f;
                            } completion:^(__unused BOOL finished) {
                                [snapshot removeFromSuperview];
                            }];
                            
                            CGRect updatedFrame = [strongSelf.collectionView layoutAttributesForItemAtIndexPath:updatedIndexPath].frame;
                            CGFloat updatedVerticalOffset = [strongSelf.collectionView convertRect:updatedFrame toView:strongSelf.view].origin.y;
                            CGFloat delta = updatedVerticalOffset - verticalOffset;
                            CGFloat contentOffsetY = strongSelf.collectionView.contentOffset.y + delta;
                            
                            if (contentOffsetY > strongSelf.collectionLayout.collectionViewContentSize.height + strongSelf.collectionView.contentInset.bottom - strongSelf.collectionView.frame.size.height) {
                                contentOffsetY = strongSelf.collectionLayout.collectionViewContentSize.height + strongSelf.collectionView.contentInset.bottom - strongSelf.collectionView.frame.size.height;
                            }
                            if (contentOffsetY < -strongSelf.collectionView.contentInset.top) {
                                contentOffsetY = -strongSelf.collectionView.contentInset.top;
                            }
                            
                            [strongSelf.collectionView setContentOffset:CGPointMake(0.0f, contentOffsetY) animated:false];
                        }
                    } else {
                        [strongSelf reloadItems];
                    }
                    
                    [strongSelf->_attachmentSheetWindow dismissAnimated:true completion:nil];
                    strongSelf->_attachmentSheetWindow = nil;
                }
            }
        };
        [items addObject:itemView];
    }
    
    _attachmentSheetWindow.view.cancel = ^{
        __strong TGPaymentCheckoutController *strongSelf = weakSelf;
        if (strongSelf != nil) {
            [strongSelf->_attachmentSheetWindow dismissAnimated:true completion:nil];
            strongSelf->_attachmentSheetWindow = nil;
        }
    };
    
    _attachmentSheetWindow.view.items = items;
    [_attachmentSheetWindow showAnimated:true completion:nil];
}

- (void)showPaymentMethodSheet {
    [_attachmentSheetWindow dismissAnimated:true completion:nil];
    
    NSMutableArray *updatedPaymentMethods = [[NSMutableArray alloc] initWithArray:_paymentMethods.methods];
    NSUInteger updatedSelectedIndex = _paymentMethods.selectedIndex;
    bool found = false;
    for (id method in updatedPaymentMethods) {
        if ([method isKindOfClass:[TGPaymentMethodApplePay class]]) {
            found = true;
            break;
        }
    }
    bool enableApplePay = false;
    if (iosMajorVersion() >= 8) {
        if ([TGPaymentMethodController supportsApplePay]) {
            enableApplePay = true;
        }
    }
    if (!found && enableApplePay) {
        if ([TGPaymentMethodController supportsApplePay] && (isNativeApplePayProvider(_paymentForm.nativeProvider))) {
            [updatedPaymentMethods insertObject:[[TGPaymentMethodApplePay alloc] init] atIndex:0];
            updatedSelectedIndex += 1;
        }
    }
    
    if (updatedPaymentMethods.count == 0) {
        [self showAddNewPaymentMethodController];
    } else {
        __weak TGPaymentCheckoutController *weakSelf = self;
        _attachmentSheetWindow = [[TGShareSheetWindow alloc] init];
        _attachmentSheetWindow.dismissalBlock = ^
        {
            __strong TGPaymentCheckoutController *strongSelf = weakSelf;
            if (strongSelf == nil)
                return;
            
            strongSelf->_attachmentSheetWindow.rootViewController = nil;
            strongSelf->_attachmentSheetWindow = nil;
        };
        
        NSMutableArray *items = [[NSMutableArray alloc] init];
        
        [items addObject:[[TGShareSheetTitleItemView alloc] initWithTitle:TGLocalized(@"Checkout.PaymentMethod.Title")]];
        
        NSUInteger index = 0;
        UIImage *applyPayImage = [UIImage imageNamed:@"Apple_Pay_Payment_Mark.png"];
        for (id<TGPaymentMethod> method in updatedPaymentMethods) {
            TGAttachmentSheetCheckmarkVariantItemView *itemView = [[TGAttachmentSheetCheckmarkVariantItemView alloc] initWithTitle:[method title] variant:@"" checked:index == updatedSelectedIndex image:[method isKindOfClass:[TGPaymentMethodApplePay class]] ? applyPayImage : nil];
            itemView.disableAutoCheck = true;
            itemView.disableInsetIfNotChecked = _paymentMethods == nil || _paymentMethods.selectedIndex == NSNotFound;
            itemView.onCheckedChanged = ^(bool value) {
                if (value) {
                    __strong TGPaymentCheckoutController *strongSelf = weakSelf;
                    if (strongSelf != nil) {
                        strongSelf->_paymentMethods = [[TGPaymentMethods alloc] initWithMethods:updatedPaymentMethods selectedIndex:index];
                        
                        [strongSelf reloadItems];
                    
                        [strongSelf->_attachmentSheetWindow dismissAnimated:true completion:nil];
                        strongSelf->_attachmentSheetWindow = nil;
                    }
                }
            };
            [items addObject:itemView];
            
            index += 1;
        }
        
        TGShareSheetButtonItemView *addButtonItem = [[TGShareSheetButtonItemView alloc] initWithTitle:TGLocalized(@"Checkout.PaymentMethod.New") pressed:^ {
            __strong TGPaymentCheckoutController *strongSelf = weakSelf;
            if (strongSelf != nil) {
                [strongSelf->_attachmentSheetWindow dismissAnimated:true completion:nil];
                strongSelf->_attachmentSheetWindow = nil;
                
                [strongSelf showAddNewPaymentMethodController];
            }
        }];
        [items addObject:addButtonItem];
        
        _attachmentSheetWindow.view.cancel = ^{
            __strong TGPaymentCheckoutController *strongSelf = weakSelf;
            if (strongSelf != nil) {
                [strongSelf->_attachmentSheetWindow dismissAnimated:true completion:nil];
                strongSelf->_attachmentSheetWindow = nil;
            }
        };
        
        _attachmentSheetWindow.view.items = items;
        [_attachmentSheetWindow showAnimated:true completion:nil];
    }
}

- (void)showAddNewPaymentMethodController {
    NSString *useWebviewUrl = ([_paymentForm.nativeProvider isEqualToString:@"stripe"] && _paymentForm.nativeParams.length != 0) ? nil : _paymentForm.url;
    
    if (useWebviewUrl != nil) {
        bool canSave = self->_paymentForm.canSaveCredentials || self->_paymentForm.passwordMissing;
        bool allowSaving = self->_paymentForm.canSaveCredentials && !_paymentForm.passwordMissing;
        
        TGPaymentWebController *controller = [[TGPaymentWebController alloc] initWithUrl:useWebviewUrl confirmation:false canSave:canSave allowSaving:allowSaving];
        __weak TGPaymentCheckoutController *weakSelf = self;
        controller.completed = ^(NSString *data, NSString *title, bool save) {
            __strong TGPaymentCheckoutController *strongSelf = weakSelf;
            if (strongSelf != nil && data != nil && title != nil) {
                id<TGPaymentMethod> addedMethod = [[TGPaymentMethodWebToken alloc] initWithJsonData:data title:title saveCredentials:save];
                
                NSMutableArray *updatedMethods = [[NSMutableArray alloc] init];
                [updatedMethods addObject:addedMethod];
                
                bool enableApplePay = false;
                if (iosMajorVersion() >= 8) {
                    if ([TGPaymentMethodController supportsApplePay]) {
                        enableApplePay = true;
                    }
                }
                
                if (enableApplePay) {
                    if ([TGPaymentMethodController supportsApplePay] && isNativeApplePayProvider(strongSelf->_paymentForm.nativeProvider)) {
                        [updatedMethods insertObject:[[TGPaymentMethodApplePay alloc] init] atIndex:0];
                    }
                }
                
                strongSelf->_paymentMethods = [[TGPaymentMethods alloc] initWithMethods:updatedMethods selectedIndex:updatedMethods.count - 1];
                
                [strongSelf dismissViewControllerAnimated:true completion:nil];
                [strongSelf reloadItems];
            }
        };
        [self presentViewController:[TGNavigationController navigationControllerWithRootController:controller] animated:true completion:nil];
    } else if (_paymentForm.nativeParams != nil) {
        __weak TGPaymentCheckoutController *weakSelf = self;
        void (^addCard)() = ^{
            __strong TGPaymentCheckoutController *strongSelf = weakSelf;
            if (strongSelf != nil) {
                NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:[strongSelf->_paymentForm.nativeParams dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                if (dict != nil) {
                    bool canSave = strongSelf->_paymentForm.canSaveCredentials || (strongSelf->_paymentForm.passwordMissing || strongSelf->_overridePasswordMissing);
                    bool allowSaving = !(strongSelf->_paymentForm.passwordMissing && !strongSelf->_overridePasswordMissing);
                    
                    TGAddPaymentCardController *addController = [[TGAddPaymentCardController alloc] initWithCanSave:canSave allowSaving:allowSaving requestCountry:[dict[@"need_country"] boolValue] requestPostcode:[dict[@"need_zip"] boolValue] requestName:[dict[@"need_cardholder_name"] boolValue] publishableKey:dict[@"publishable_key"]];
                    addController.canSaveUpdated = ^(bool value) {
                        __strong TGPaymentCheckoutController *strongSelf = weakSelf;
                        if (strongSelf != nil) {
                            if (value) {
                                strongSelf->_overridePasswordMissing = true;
                            }
                        }
                    };
                    addController.completion = ^(TGPaymentMethodStripeToken *token) {
                        __strong TGPaymentCheckoutController *strongSelf = weakSelf;
                        if (strongSelf != nil && token != nil) {
                            id<TGPaymentMethod> addedMethod = token;
                            
                            NSMutableArray *updatedMethods = [[NSMutableArray alloc] init];
                            [updatedMethods addObject:addedMethod];
                            
                            bool enableApplePay = false;
                            if (iosMajorVersion() >= 8) {
                                if ([TGPaymentMethodController supportsApplePay]) {
                                    enableApplePay = true;
                                }
                            }
                            
                            if (enableApplePay) {
                                if ([TGPaymentMethodController supportsApplePay] && isNativeApplePayProvider(strongSelf->_paymentForm.nativeProvider)) {
                                    [updatedMethods insertObject:[[TGPaymentMethodApplePay alloc] init] atIndex:0];
                                }
                            }
                            
                            strongSelf->_paymentMethods = [[TGPaymentMethods alloc] initWithMethods:updatedMethods selectedIndex:updatedMethods.count - 1];
                            
                            [strongSelf reloadItems];
                        }
                    };
                    [strongSelf presentViewController:[TGNavigationController navigationControllerWithRootController:addController] animated:true completion:nil];
                }
            }
        };
        
        addCard();
    }
}

@end
