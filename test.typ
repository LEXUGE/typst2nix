#{
  import "@preview/quill:0.2.0": *
  quantum-circuit(
    lstick($|0〉$),
    gate($H$),
    ctrl(1),
    rstick($(|00〉+|11〉)/√2$, n: 2),
    [\ ],
    lstick($|0〉$),
    1,
    targ(),
    1,
  )
}
