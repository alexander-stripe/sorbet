#include "rewriter/initializer.h"
#include "ast/Helpers.h"
#include "ast/ast.h"
#include "core/core.h"

#include <utility>

using namespace std;
namespace sorbet::rewriter {

bool isSig(const ast::Send *send) {
    if (send->fun != core::Names::sig()) {
        return false;
    }
    if (send->block.get() == nullptr) {
        return false;
    }
    auto nargs = send->args.size();
    if (nargs != 0 && nargs != 1) {
        return false;
    }
    auto block = ast::cast_tree<ast::Block>(send->block.get());
    ENFORCE(block);
    auto body = ast::cast_tree<ast::Send>(block->body.get());
    if (!body) {
        return false;
    }
    if (body->fun != core::Names::void_()) {
        return false;
    }

    return true;
}

// if expr is of the form `@var = local`, and `local` is typed, then replace it with with `@var = T.let(local,
// type_of_local)`
void maybeAddLet(core::MutableContext ctx, ast::Expression *expr,
                 const UnorderedMap<core::NameRef, ast::Expression *> &argTypeMap) {
    auto assn = ast::cast_tree<ast::Assign>(expr);
    if (!assn) {
        return;
    }

    auto lhs = ast::cast_tree<ast::UnresolvedIdent>(assn->lhs.get());
    if (!lhs || lhs->kind != ast::UnresolvedIdent::Instance) {
        return;
    }

    auto rhs = ast::cast_tree<ast::UnresolvedIdent>(assn->rhs.get());
    if (!rhs || rhs->kind != ast::UnresolvedIdent::Local) {
        return;
    }

    auto typeExpr = argTypeMap.find(rhs->name);
    if (typeExpr != argTypeMap.end()) {
        auto loc = rhs->loc;
        auto newLet = ast::MK::Let(loc, move(assn->rhs), typeExpr->second->deepCopy());
        assn->rhs = move(newLet);
    }
}

// this walks through the chain of sends contained in the body of the `sig` block to find the `params` one, if it
// exists; and otherwise returns a null pointer
ast::Hash *findParamHash(const ast::Send *send) {
    while (send && send->fun != core::Names::params()) {
        send = ast::cast_tree<ast::Send>(send->recv.get());
    }
    if (!send || send->args.size() != 1) {
        return nullptr;
    }
    return ast::cast_tree<ast::Hash>(send->args.front().get());
}

void Initializer::run(core::MutableContext ctx, ast::MethodDef *methodDef, const ast::Expression *prevStat) {
    // this should only run in an `initialize` that has a sig
    if (methodDef->name != core::Names::initialize()) {
        return;
    }
    if (prevStat == nullptr) {
        return;
    }
    // make sure that the `sig` block looks like a valid sig block
    auto sig = ast::cast_tree_const<ast::Send>(prevStat);
    if (!sig || !isSig(sig)) {
        return;
    }
    auto block = ast::cast_tree<ast::Block>(sig->block.get());
    if (!block) {
        return;
    }

    // walk through, find the `params()` invocation, and get its hash
    auto argHash = findParamHash(ast::cast_tree<ast::Send>(block->body.get()));
    if (!argHash) {
        return;
    }

    // build a lookup table that maps from names to the expressions they have
    UnorderedMap<core::NameRef, ast::Expression *> argTypeMap;
    for (int i = 0; i < argHash->keys.size(); i++) {
        auto argName = ast::cast_tree<ast::Literal>(argHash->keys[i].get());
        auto argVal = argHash->values[i].get();
        if (argName->isSymbol(ctx)) {
            argTypeMap[argName->asSymbol(ctx)] = argVal;
        }
    }

    // look through the rhs to find statements of the form `@var = local`
    if (auto stmts = ast::cast_tree<ast::InsSeq>(methodDef->rhs.get())) {
        for (auto &s : stmts->stats) {
            maybeAddLet(ctx, s.get(), argTypeMap);
        }
        maybeAddLet(ctx, stmts->expr.get(), argTypeMap);
    } else {
        maybeAddLet(ctx, methodDef->rhs.get(), argTypeMap);
    }
}

} // namespace sorbet::rewriter
