(comment) @spell

(directive
    name: (type) @directive
    body: (body
        (content) @spell
        (#not-match? @directive "code-block")
    )
)

(paragraph) @spell
