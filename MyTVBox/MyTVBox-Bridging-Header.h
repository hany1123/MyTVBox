//
//  MyTVBox-Bridging-Header.h
//  MyTVBox
//

#ifndef MyTVBox_Bridging_Header_h
#define MyTVBox_Bridging_Header_h

#include <CommonCrypto/CommonCrypto.h>

// 1.7.0：端上 Node 运行时（nodejs-mobile v18.20.4）
// 只暴露一个 C 接口：int node_start(int argc, char *argv[]);
#import <NodeMobile/NodeMobile.h>

#endif /* MyTVBox_Bridging_Header_h */
