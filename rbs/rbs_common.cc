#include "rbs/rbs_common.h"

namespace sorbet::rbs {

core::LocOffsets RBSDeclaration::commentLoc() const {
    return comments.front().commentLoc.join(comments.back().commentLoc);
}

core::LocOffsets RBSDeclaration::firstLineTypeLoc() const {
    return comments.front().typeLoc;
}

core::LocOffsets RBSDeclaration::fullTypeLoc() const {
    return comments.front().typeLoc.join(comments.back().typeLoc);
}

core::LocOffsets RBSDeclaration::typeLocFromRange(const rbs_range_t &range) const {
    int rangeOffset = range.start.char_pos;
    int rangeLength = range.end.char_pos - range.start.char_pos;

    for (const auto &comment : comments) {
        int commentTypeLength = comment.typeLoc.endLoc - comment.typeLoc.beginLoc;
        if (rangeOffset < commentTypeLength) {
            auto beginLoc = comment.typeLoc.beginLoc + rangeOffset;
            auto endLoc = beginLoc + rangeLength;

            if (rangeLength > commentTypeLength) {
                endLoc = comment.typeLoc.endLoc;
            }

            return core::LocOffsets{beginLoc, endLoc};
        }
        rangeOffset -= commentTypeLength;
    }
    return comments.front().typeLoc;
}
} // namespace sorbet::rbs
