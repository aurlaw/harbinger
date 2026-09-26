BIN := ../bin/harbinger

.PHONY: build test lint

build:
	mkdir -p $(dir $(BIN))
	go build -o $(BIN) ./cmd/harbinger

test:
	go test -race ./...

lint:
	@unformatted="$$(gofmt -l .)"; \
	if [ -n "$$unformatted" ]; then echo "gofmt needed:"; echo "$$unformatted"; exit 1; fi
	go vet ./...
