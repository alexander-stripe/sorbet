cc_library(
    name = "com_github_d_bahr_crcpp",
    hdrs = ["inc/CRC.h"],
    includes = ["inc"],
    linkstatic = select({
        "@com_stripe_ruby_typer//tools/config:linkshared": 0,
        "//conditions:default": 1,
    }),
    visibility = ["//visibility:public"],
)
