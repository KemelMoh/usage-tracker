import SwiftUI
import AppKit
import UsageTrackerCore

struct ModelsCatalogView: View {
    @ObservedObject var model: AppModel
    var compact: Bool = true

    @State private var query = ""
    @State private var providerFilter: ProviderID?
    @State private var collapsedProviders: Set<ProviderID> = []
    @State private var expandedModel: String?
    @State private var showRecommendedOnly = true

    /// Las recomendaciones vienen ya calculadas desde `AppModel`: recorrer y
    /// ordenar el catálogo entero por cada pasada de render era el mayor coste
    /// de esta vista.
    private var recommendationIndex: RecommendationIndex {
        model.recommendationIndex
    }

    private var recommendationByModelID: [String: WorkloadBadge] {
        recommendationIndex.badgeByModelID
    }

    private var providersWithoutRecommendations: [ProviderID] {
        recommendationIndex.providersBelowMinimum.filter {
            model.subscription(for: $0).isActive
        }
    }

    /// Solo los proveedores que tienen modelos en el catálogo. Un proveedor sin
    /// modelos no aparece en el filtro: elegirlo solo llevaría a una lista vacía.
    private var availableProviders: [ProviderID] {
        let activeProviders = Set(model.activeProviders)
        let withModels = Set(model.catalogModels.map(\.provider))
        return ProviderID.allCases.filter {
            activeProviders.contains($0) && withModels.contains($0)
        }
    }

    /// Filtra y agrupa el catálogo en una sola pasada.
    ///
    /// Antes esto eran tres propiedades calculadas independientes: cada una
    /// filtraba y ordenaba el catálogo entero, y `groups` volvía a filtrarlo
    /// una vez por proveedor. Ahora el resultado se calcula una vez por pasada
    /// de render y se reutiliza en el contador y en la lista.
    private func makeGroups() -> CatalogGroups {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let recommendedIDs = recommendationIndex.recommendedModelIDs
        let order = recommendationIndex.orderByModelID
        let onlyRecommended = model.modelRecommendationsEnabled && showRecommendedOnly
        let activeProviders = Set(model.activeProviders)

        var buckets: [ProviderID: [CatalogModel]] = [:]
        var total = 0

        for entry in model.catalogModels {
            guard activeProviders.contains(entry.provider) else { continue }
            if let providerFilter, entry.provider != providerFilter { continue }
            if !search.isEmpty {
                let name = entry.name.lowercased()
                let id = entry.modelID.lowercased()
                guard name.contains(search) || id.contains(search) else { continue }
            }
            if onlyRecommended && !recommendedIDs.contains(entry.id) { continue }
            buckets[entry.provider, default: []].append(entry)
            total += 1
        }

        let groups = ProviderID.allCases.compactMap { provider -> (ProviderID, [CatalogModel])? in
            guard var entries = buckets[provider], !entries.isEmpty else { return nil }
            if onlyRecommended {
                entries.sort { (order[$0.id] ?? 99) < (order[$1.id] ?? 99) }
            }
            return (provider, entries)
        }

        return CatalogGroups(groups: groups, total: total)
    }

    var body: some View {
        // El filtrado se resuelve una única vez por pasada de render y se
        // comparte entre el contador, la lista y los avisos.
        let result = makeGroups()
        return Group {
            if compact {
                compactBody(result)
            } else {
                fullBody(result)
            }
        }
        .onChange(of: model.activeProviders) { activeProviders in
            if let providerFilter, !activeProviders.contains(providerFilter) {
                self.providerFilter = nil
            }
        }
    }

    private func compactBody(_ result: CatalogGroups) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.catalogError, !model.catalogModels.isEmpty {
                ErrorBanner(message: error, onDismiss: model.clearCatalogError)
            }

            controls(result.total)

            if model.catalogModels.isEmpty {
                placeholder
            } else if result.groups.isEmpty {
                emptyModelState
            } else {
                ScrollView {
                    listContent(result.groups)
                }
            }

            footnote
        }
    }

    private func fullBody(_ result: CatalogGroups) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Modelos")
                            .font(.largeTitle.weight(.bold))
                        Text("Disponibles en tus proveedores, con precios públicos por token")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await model.refreshCatalog() }
                    } label: {
                        Label("Actualizar catálogo", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(model.isCatalogLoading)
                }

                controls(result.total)

                if let error = model.catalogError {
                    ErrorBanner(message: error, onDismiss: model.clearCatalogError)
                }

                if model.catalogModels.isEmpty {
                    placeholder
                } else if result.groups.isEmpty {
                    emptyModelState
                } else {
                    listContent(result.groups)
                }

                footnote
            }
            .padding(24)
        }
    }

    private var emptyModelState: some View {
        let activeProviders = Set(model.activeProviders)
        let hasModelsForActiveProviders = model.catalogModels.contains {
            activeProviders.contains($0.provider)
        }
        let title: String
        let message: String

        if activeProviders.isEmpty {
            title = "Sin suscripciones activas"
            message = "Activa al menos un proveedor en Suscripciones para ver sus modelos."
        } else if hasModelsForActiveProviders {
            title = "Sin resultados"
            message = "No hay modelos que coincidan con los filtros actuales."
        } else {
            title = "Modelos no disponibles"
            message = "El catálogo no tiene modelos para tus proveedores activos."
        }

        return EmptyState(
            symbol: "square.stack.3d.up.slash",
            title: title,
            message: message
        )
        .card(padding: 16)
    }

    private func controls(_ totalCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                searchField

                Picker("Proveedor", selection: $providerFilter) {
                    Text("Todos").tag(ProviderID?.none)
                    ForEach(availableProviders) { provider in
                        Text(provider.displayName).tag(Optional(provider))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            HStack(spacing: 6) {
                Text("\(totalCount) modelos")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if !query.isEmpty || providerFilter != nil {
                    Button("Limpiar") {
                        query = ""
                        providerFilter = nil
                    }
                    .font(.caption2)
                    .buttonStyle(.link)
                }

                Spacer()

                if model.modelRecommendationsEnabled {
                    Toggle(isOn: $showRecommendedOnly) {
                        Label("Recomendados", systemImage: "sparkles")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Mostrar solo los modelos recomendados por proveedor")
                }

                if model.isCatalogLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if model.modelRecommendationsEnabled,
               showRecommendedOnly,
               !providersWithoutRecommendations.isEmpty {
                Text("Sin 3 modelos válidos en \(providersWithoutRecommendations.map(\.displayName).joined(separator: ", ")).")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Buscar modelo…", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Borrar búsqueda")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.secondary.opacity(0.22))
        )
    }

    private func listContent(_ groups: [(provider: ProviderID, entries: [CatalogModel])]) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.provider) { group in
                providerSection(group.provider, entries: group.entries)
            }
        }
        .padding(.bottom, 2)
    }

    private func providerSection(_ provider: ProviderID, entries: [CatalogModel]) -> some View {
        let isOpen = !query.isEmpty || !collapsedProviders.contains(provider)

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                guard query.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    if collapsedProviders.contains(provider) {
                        collapsedProviders.remove(provider)
                    } else {
                        collapsedProviders.insert(provider)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 9)
                    ProviderIcon(provider: provider, size: 16)
                    Text(provider.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text("\(entries.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().padding(.leading, 10)
                        }
                        row(entry)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.14))
                )
                .transition(.opacity)
            }
        }
    }

    private func row(_ entry: CatalogModel) -> some View {
        let isExpanded = expandedModel == entry.id

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if let context = entry.contextWindow {
                    Text("\(Format.tokens(context)) ctx")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                if let discount = entry.discount {
                    campaignBadge(discount)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }

            HStack(spacing: 6) {
                if let badge = recommendationByModelID[entry.id] {
                    recommendationBadge(badge, provider: entry.provider)
                }
                if entry.discount != nil, let listPrice = listPriceLine(entry) {
                    Text(listPrice)
                        .strikethrough()
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text(priceLine(entry))
                Spacer(minLength: 4)
                if entry.isFree && entry.discount == nil {
                    freeTag
                }
                if entry.reasoning {
                    tag("razona")
                }
                if entry.toolCall {
                    tag("tools")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if isExpanded {
                details(entry)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .opacity(entry.hasPublishedPrice ? 1 : 0.65)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.12)) {
                expandedModel = isExpanded ? nil : entry.id
            }
        }
    }

    private func details(_ entry: CatalogModel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
                .padding(.vertical, 2)

            if let input = entry.inputPerMillion {
                detailLine("Entrada", "\(Format.pricePerMillion(input)) / 1M")
            }
            if let output = entry.outputPerMillion {
                detailLine("Salida", "\(Format.pricePerMillion(output)) / 1M")
            }
            if let cacheRead = entry.cacheReadPerMillion {
                detailLine("Caché lectura", "\(Format.pricePerMillion(cacheRead)) / 1M")
            }
            if let cacheWrite = entry.cacheWritePerMillion {
                detailLine("Caché escritura", "\(Format.pricePerMillion(cacheWrite)) / 1M")
            }
            if let context = entry.contextWindow {
                detailLine("Contexto", "\(Format.tokens(context)) tokens")
            }
            if let output = entry.maxOutput {
                detailLine("Salida máxima", "\(Format.tokens(output)) tokens")
            }
            if !entry.hasPublishedPrice {
                Text("models.dev no publica tarifa para este modelo.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Text(entry.modelID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Copiar id") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.modelID, forType: .string)
                }
                .buttonStyle(.link)
            }
            .font(.caption2)
            .padding(.top, 2)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption2)
    }

    private func priceLine(_ entry: CatalogModel) -> String {
        var parts: [String] = []
        if let input = entry.inputPerMillion {
            parts.append("Entrada \(Format.pricePerMillion(input))")
        }
        if let output = entry.outputPerMillion {
            parts.append("Salida \(Format.pricePerMillion(output))")
        }
        return parts.isEmpty ? "Sin tarifa publicada" : parts.joined(separator: " · ")
    }

    private func listPriceLine(_ entry: CatalogModel) -> String? {
        var parts: [String] = []
        if let input = entry.listInputPerMillion {
            parts.append("Entrada \(Format.pricePerMillion(input))")
        }
        if let output = entry.listOutputPerMillion {
            parts.append("Salida \(Format.pricePerMillion(output))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func campaignBadge(_ discount: Double) -> some View {
        let text = discount >= 0.995 ? "Gratis" : "−\(Format.percent(discount * 100))"
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.14), in: Capsule())
            .foregroundStyle(.green)
            .help("LiteLLM cobra menos que el precio de lista de LiteLLM")
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.14), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var freeTag: some View {
        HStack(spacing: 3) {
            Image(systemName: "gift.fill")
            Text("Gratis")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color.green.opacity(0.14), in: Capsule())
        .foregroundStyle(.green)
        .help("Modelo con tarifa publicada de 0 USD por millón de tokens")
        .accessibilityLabel("Modelo gratuito")
    }

    private func recommendationBadge(_ badge: WorkloadBadge, provider: ProviderID) -> some View {
        let cap = WorkloadPriceCaps.cap(badge, for: provider)
        return HStack(spacing: 3) {
            Image(systemName: badge.symbolName)
            Text(badge.title)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(recommendationColor(badge).opacity(0.15), in: Capsule())
        .foregroundStyle(recommendationColor(badge))
        .help("Recomendado para \(badge.title.lowercased()). Tope: \(String(format: "$%.2f", cap.maxInputPerMillion)) entrada / \(String(format: "$%.2f", cap.maxOutputPerMillion)) salida por 1M.")
        .accessibilityLabel("Recomendado: \(badge.title)")
    }

    private func recommendationColor(_ badge: WorkloadBadge) -> Color {
        switch badge {
        case .ultra: return .purple
        case .medium: return .blue
        case .light: return .green
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.isCatalogLoading {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Cargando catálogo de modelos…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("Catálogo no disponible")
                    .font(.headline)
                Text(model.catalogError ?? "Pulsa actualizar para descargar la lista de modelos y sus precios.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Cargar modelos") {
                    Task { await model.refreshCatalog() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isCatalogLoading)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Precios en USD por 1M de tokens, según models.dev. Pueden no coincidir con tu factura.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Gratis = 0 USD por millón de tokens. models.dev no publica políticas de datos; no se puede indicar qué modelos entrenan con tus datos.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !compact {
                Text(model.catalogUpdatedText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Resultado del filtrado del catálogo para una pasada de render.
struct CatalogGroups {
    let groups: [(provider: ProviderID, entries: [CatalogModel])]
    /// Número total de modelos tras filtrar.
    let total: Int
}
