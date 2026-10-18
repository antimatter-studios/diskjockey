#import <Foundation/Foundation.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Queue-only entry points. The connection owner comes from the agent listener.
typedef void (^DJAgentOwnedAttachReply)(uint64_t, NSString * _Nullable, NSString * _Nullable);
typedef void (^DJAgentOwnedDetachReply)(BOOL, NSString * _Nullable);
void DJAgentOwnedImageAttach(uint64_t owner, const char * _Nonnull path, int proof,
    uint64_t offset, uint64_t length, uint32_t blockSize, DJAgentOwnedAttachReply _Nonnull reply);
void DJAgentOwnedImageDetach(uint64_t owner, uint64_t identity, DJAgentOwnedDetachReply _Nonnull reply);
#ifdef __cplusplus
}
#endif
